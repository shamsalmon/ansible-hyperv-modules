#!powershell

#Requires -Module Ansible.ModuleUtils.Legacy

$ErrorActionPreference = 'Stop'

function Normalize-MacAddress ([string]$value) {
    $value.`
        Replace('-', '').`
        Replace(':', '').`
        Insert(2,':').Insert(5,':').Insert(8,':').Insert(11,':').Insert(14,':').`
        ToLowerInvariant()
}

Function Write-DebugLog {
    Param(
    [string]$msg
    )

    $DebugPreference = "Continue"
    $ErrorActionPreference = "Continue"
    $date_str = Get-Date -Format u
    $msg = "$date_str $msg"

    Write-Debug $msg

    if($log_path) {
        Add-Content $log_path $msg
    }
}

#$params_obj = Parse-Args -arguments $args -supports_check_mode $true
#Write-Host $params_obj
#$params = @{}

#foreach ($property in $params_obj.PSObject.Properties) {
#    $params[$property.Name] = $property.Value
#}

$result = @{
    changed = $true
    status = ""
}

$params = Parse-Args -arguments $args -supports_check_mode $true
$check_mode = Get-AnsibleParam -obj $params -name "_ansible_check_mode" -type "bool" -default $false
$state = Get-AnsibleParam -obj $params -name "state" -type "str" -default "present" -validateset "absent", "present"
$vm_name = Get-AnsibleParam -obj $params -name "vm_name" -type "str" -failifempty $true
$fqdn = Get-AnsibleParam -obj $params -name "fqdn" -type "str" -default "$vm_name.entech.local"
$root_password = Get-AnsibleParam -obj $params -name "root_password" -type "str"
$root_public_key = Get-AnsibleParam -obj $params -name "root_public_key" -type "str"-failifempty ($root_password -eq $null)
$vhdx_origin =  Get-AnsibleParam -obj $params -name "vhdx_origin" -type "str" -failifempty $true
$vlan_id = Get-AnsibleParam -obj $params -name "vlan_id" -type "str" -failifempty $true
$vhdx_size_bytes = Get-AnsibleParam -obj $params -name "vhdx_size_bytes" -type "uint64" -default 50GB
$destination_volume = Get-AnsibleParam -obj $params -name "destination_volume" -type "str" -failifempty $true
$switch_name = Get-AnsibleParam -obj $params -name "switch_name" -type "str" -failifempty $true
$ip_address = Get-AnsibleParam -obj $params -name "ip_address" -type "str" -failifempty $true
$gateway = Get-AnsibleParam -obj $params -name "gateway" -type "str" -failifempty $true
$dns_addresses = Get-AnsibleParam -obj $params -name "dns_addresses" -type "list" -failifempty $true
$memory_startup_bytes = Get-AnsibleParam -obj $params -name "memory_startup_bytes" -type "uint64" -default 2GB
$enable_dynamic_memory = Get-AnsibleParam -obj $params -name "enable_dynamic_memory" -type "bool" -default $true
$processor_count = 2
$mac_address = Get-AnsibleParam -obj $params -name "mac_address" -type "str"
$interface_name = 'eth0'
$enable_routing = $false
$install_docker = Get-AnsibleParam -obj $params -name "install_docker" -type "str"
$log_path = Get-AnsibleParam -obj $params -name "log_path" -type "str"

$secondary_ip_address = Get-AnsibleParam -obj $params -name "ip_address" -type "str"
$secondary_switch_name = Get-AnsibleParam -obj $params -name "switch_name" -type "str"
$secondary_mac_address = Get-AnsibleParam -obj $params -name "mac_address" -type "str"
$secondary_interface_name = Get-AnsibleParam -obj $params -name "secondary_interface_name" -type "str"
$loopback_ip_address = Get-AnsibleParam -obj $params -name "loopback_ip_address" -type "str"

Try {
    $vmms = gwmi -namespace root\virtualization\v2 Msvm_VirtualSystemManagementService
    $vmmsSettings = gwmi -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
    $destinationFolder = "$destination_volume\$vm_name".trimend('\')
    $vhdPath ="$destinationFolder\Virtual Hard Disk" 
    $vmPath = "$destinationFolder\Virtual Machines\"
    $metadataIso = "$vhdPath\$($vm_name)_metadata.iso"
    $vhdxPath = "$vhdPath\$($vm_name)_os.vhdx"

    # Check if exists
    $vmc = Get-VM -name $vm_name -ErrorAction SilentlyContinue
    if ($null -ne $vmc) {
        $result.changed = $false
        $result.status = "present"
        Exit-Json -obj $result -message "VM Already Exists"
    }

    If(!(test-path $vhdPath))
    {
          New-Item -ItemType Directory -Force -Path $vhdPath
    }

    # Copy VHDX
    Write-DebugLog "Copying $vhdx_origin to $vhdxPath"
    Copy-Item $vhdx_origin -Destination $vhdxPath

    # Resize
    Write-DebugLog 'Resizing VHDX'
    Resize-VHD -Path $vhdxPath -SizeByte $vhdx_size_bytes

    # Create VM
    Write-DebugLog 'Creating VM...'
    $vm = New-VM -Name $vm_name -Generation 2 -MemoryStartupBytes $memory_startup_bytes -VHDPath $vhdxPath -Path $vmPath -SwitchName $switch_name
    $vm | Set-VMProcessor -Count $processor_count
    $vm | Get-VMIntegrationService -Name "Guest Service Interface" | Enable-VMIntegrationService
    if ($enable_dynamic_memory) {
        $vm | Set-VMMemory -DynamicMemoryEnabled $true 
    }
    # Sets Secure Boot Template. 
    #   Set-VMFirmware -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' doesn't work anymore (!?).
    $vm | Set-VMFirmware -SecureBootTemplateId ([guid]'272e7447-90a4-4563-a4b9-8e4ab00526ce')

    # Ubuntu 16.04/18.04 startup hangs without a serial port (!?) -- https://bit.ly/2AhsihL
    $vm | Set-VMComPort -Number 2 -Path "\\.\pipe\dbg1"

    # Setup first network adapter
    if ($mac_address) {
        $mac_address = Normalize-MacAddress $mac_address
        $vm | Set-VMNetworkAdapter -StaticMacAddress $mac_address.Replace(':', '')
    }
    $eth0 = Get-VMNetworkAdapter -VMName $vm_name 
    $eth0 | Rename-VMNetworkAdapter -NewName $interface_name
    # Set VLAN ID
    $eth0 | Set-VMNetworkAdapterVlan -VlanID $vlan_id -Access

    # Start VM just to create MAC Addresses
    $vm | Start-VM
    Start-Sleep -Seconds 1
    $vm | Stop-VM -Force


    # Wait for Mac Addresses
    Write-DebugLog "Waiting for MAC addresses..."
    do {
        $eth0 = Get-VMNetworkAdapter -VMName $vm_name -Name $interface_name
        $mac_address = Normalize-MacAddress $eth0.MacAddress
        Start-Sleep -Seconds 1
    } while ($mac_address -eq '00:00:00:00:00:00')

    if ($secondary_switch_name) {
        do {
            $eth1 = Get-VMNetworkAdapter -VMName $vm_name -Name $secondary_interface_name
            $secondary_mac_address = Normalize-MacAddress $eth1.MacAddress
            Start-Sleep -Seconds 1
        } while ($secondary_mac_address -eq '00:00:00:00:00:00')
    }

    # Create metadata ISO image
    #   Creates a NoCloud data source for cloud-init.
    #   More info: http://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html
    Write-DebugLog 'Creating metadata ISO image...'
    $instanceId = [Guid]::NewGuid().ToString()
    
    $metadata = @"
instance-id: $instanceId
local-hostname: $vm_name
"@

    $RouterMark = if ($enable_routing) { '<->' } else { '   ' }
    $IpForward = if ($enable_routing) { 'IPForward=yes' } else { '' }
    $IpMasquerade = if ($enable_routing) { 'IPMasquerade=yes' } else { '' }
    if ($secondary_switch_name) {
        $DisplayInterfaces = "     $($interface_name): \4{$interface_name}  $RouterMark  $($secondary_interface_name): \4{$secondary_interface_name}"
    } else {
        $DisplayInterfaces = "     $($interface_name): \4{$interface_name}"
    }

    $sectionWriteFiles = @"
write_files:
 - content: |
     \S{PRETTY_NAME} \n \l
$DisplayInterfaces
     
   path: /etc/issue
   owner: root:root
   permissions: '0644'
 - content: |
     [Match]
     MACAddress=$mac_address
     [Link]
     Name=$interface_name
   path: /etc/systemd/network/20-$interface_name.link
   owner: root:root
   permissions: '0644'
 - content: |
     # Please see /etc/systemd/network/ for current configuration.
     # 
     # systemd.network(5) was used directly to configure this system
     # due to limitations of netplan(5).
   path: /etc/netplan/README
   owner: root:root
   permissions: '0644'
"@

    if ($ip_address) {
        # eth0 (Static)

        # Fix for /32 addresses
        if ($ip_address.EndsWith('/32')) {
            $RouteForSlash32 = @"
     [Route]
     Destination=0.0.0.0/0
     Gateway=$gateway
     GatewayOnlink=true
"@
        }

        $sectionWriteFiles += @"
    `r`n
 - content: |
     [Match]
     Name=$interface_name
     [Network]
     Address=$ip_address
     Gateway=$gateway
     DNS=$($dns_addresses[0])
     DNS=$($dns_addresses[1])
     $IpForward
     $RouteForSlash32
   path: /etc/systemd/network/20-$interface_name.network
   owner: root:root
   permissions: '0644'
"@
    } else {
        # eth0 (DHCP)
        $sectionWriteFiles += @"
 - content: |
     [Match]
     Name==$interface_name
     [Network]
     DHCP=true
     $IpForward
     [DHCP]
     UseMTU=true
   path: /etc/systemd/network/20-=$interface_name.network
   owner: root:root
   permissions: '0644'
    }

    if ($secondary_switch_name) {
        $sectionWriteFiles += @"
 - content: |
     [Match]
     MACAddress=$secondary_mac_address
     [Link]
     Name=$secondary_interface_name
   path: /etc/systemd/network/20-$secondary_interface_name.link
   owner: root:root
   permissions: '0644'
"@

        if ($secondary_ip_address) {
            # eth1 (Static)
            $sectionWriteFiles += @"
 - content: |
     [Match]
     Name=$secondary_interface_name
     [Network]
     Address=$secondary_ip_address
     $IpForward
     $IpMasquerade
   path: /etc/systemd/network/20-$secondary_interface_name.network
   owner: root:root
   permissions: '0644'
"@
        } else {
            # eth1 (DHCP)
            $sectionWriteFiles += @"
 - content: |
     [Match]
     Name=$secondary_interface_name
     [Network]
     DHCP=true
     $IpForward
     $IpMasquerade
     [DHCP]
     UseMTU=true
   path: /etc/systemd/network/20-$secondary_interface_name.network
   owner: root:root
   permissions: '0644'
"@
        }
    }

    if ($loopback_ip_address) {
        # lo
        $sectionWriteFiles += @"
 - content: |
     [Match]
     Name=lo
     [Network]
     Address=$loopback_ip_address
   path: /etc/systemd/network/20-lo.network
   owner: root:root
   permissions: '0644'
"@
    }
        
    $sectionRunCmd = @'
runcmd:
 - 'apt-get update'
 - 'rm /etc/netplan/50-cloud-init.yaml'
 - 'touch /etc/cloud/cloud-init.disabled'
 - 'update-grub'     # fix "error: no such device: root." -- https://bit.ly/2TBEdjl
'@

    if ($root_password) {
        $sectionPasswd = @"
password: $root_password
chpasswd: { expire: False }
ssh_pwauth: True
"@
    } elseif ($root_public_key) {
        $sectionPasswd = @"
ssh_authorized_keys:
- $root_public_key
"@
    }

    if ($install_docker) {
        $sectionRunCmd += @'
- 'apt install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common'
- 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -'
- 'add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"'
- 'apt update -y'
- 'apt install -y docker-ce docker-ce-cli containerd.io docker-compose'
'@
    }

    $userdata = @"
#cloud-config
hostname: $fqdn
fqdn: $fqdn
$sectionPasswd
$sectionWriteFiles
$sectionRunCmd
power_state:
  mode: reboot
  timeout: 300
"@

    # Uses netplan to setup first network interface on first boot (due to cloud-init).
    #   Then erase netplan and uses systemd-network for everything.
    if ($ip_address) {
        # Fix for /32 addresses
        if ($ip_address.EndsWith('/32')) {
            $RouteForSlash32 = @"
    routes:
      - to: 0.0.0.0/0
        via: $gateway
        on-link: true
"@
        }

        $NetworkConfig = @"
version: 2
ethernets:
  eth0:
    addresses: [$ip_address]
    gateway4: $gateway
    nameservers:
      addresses: [$($dns_addresses -join ', ')]
    $RouteForSlash32
"@
    } else {
        $NetworkConfig = @"
version: 2
ethernets:
  eth0:
    dhcp4: true
"@
    }

    # Save all files in temp folder and create metadata .iso from it
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) $instanceId
    $tempPathOscimg = Join-Path ([System.IO.Path]::GetTempPath()) "$instanceId-oscimg"
    mkdir $tempPath | Out-Null
    mkdir $tempPathOscimg | Out-Null
    try {
        $metadata | Out-File "$tempPath\meta-data" -Encoding ascii
        $userdata | Out-File "$tempPath\user-data" -Encoding ascii
        $NetworkConfig | Out-File "$tempPath\network-config" -Encoding ascii

        Invoke-WebRequest -Uri "https://entech-public-object.s3.amazonaws.com/oscdimg.exe" -OutFile "$tempPathOscimg\oscimg.exe"
        $oscdimgPath = "$tempPathOscimg\oscimg.exe"
        & {
            Set-Alias Out-Default Out-Null
            $ErrorActionPreference = 'Continue'
            & $oscdimgPath $tempPath $metadataIso -j2 -lcidata
            if ($LASTEXITCODE -gt 0) {
                Fail-Json -obj $result -message "oscdimg.exe returned $LASTEXITCODE."
            }
        }
    }
    finally {
        rmdir -Path $tempPath -Recurse -Force
        $ErrorActionPreference = 'Stop'
    }

    # Adds DVD with metadata.iso
    $dvd = $vm | Add-VMDvdDrive -Path $metadataIso -Passthru

    # Disable Automatic Checkpoints. Check if command is available since it doesn't exist in Server 2016.
    $command = Get-Command Set-VM
    if ($command.Parameters.AutomaticCheckpointsEnabled) {
        $vm | Set-VM -AutomaticCheckpointsEnabled $false
    }

    # Wait for VM
    $vm | Start-VM
    Write-DebugLog 'Waiting for VM integration services (1)...'
    Wait-VM -Name $vm_name -For Heartbeat

    # Cloud-init will reboot after initial machine setup. Wait for it...
    Write-DebugLog 'Waiting for VM initial setup...'
    try {
        Wait-VM -Name $vm_name -For Reboot
    } catch {
        # Win 2016 RTM doesn't have "Reboot" in WaitForVMTypes type. 
        #   Wait until heartbeat service stops responding.
        $heartbeatService = ($vm | Get-VMIntegrationService -Name 'Heartbeat')
        while ($heartbeatService.PrimaryStatusDescription -eq 'OK') { Start-Sleep  1 }
    }

    Write-DebugLog 'Waiting for VM integration services (2)...'
    Wait-VM -Name $vm_name -For Heartbeat

    # Removes DVD and metadata.iso
    $dvd | Remove-VMDvdDrive
    $metadataIso | Remove-Item -Force

    # Return the VM created.
    Write-DebugLog 'All done!'

    $vm | Add-ClusterVirtualMachineRole

    $result.changed = $true
    $result.status = "present"
    Exit-Json -obj $result -message "VM Created & Clustered"

}
Catch {
    $excep = $_
    Write-DebugLog "Exception: $($excep | out-string)"
    $result.changed = $false
    Fail-Json -obj $result -message "Exception: $($excep | out-string)"
    Throw
}
