#!powershell
#AnsibleRequires -Become

#Requires -RunAsAdministrator
#Requires -Module Ansible.ModuleUtils.Legacy
#Requires -Module Ansible.ModuleUtils.ConvertWindowsImageNew
#Requires -Module Ansible.ModuleUtils.NewWindowsUnattendFile
$ErrorActionPreference = 'Stop'

function Normalize-MacAddress ([string]$value) {
    $value.`
        Replace('-', '').`
        Replace(':', '').`
        Insert(2,':').Insert(5,':').Insert(8,':').Insert(11,':').Insert(14,':').`
        ToLowerInvariant()
}

Function Invoke-Bootstrap-VM {
param(
    [Parameter(Mandatory=$true)]
    [string]$VMName,

    [Parameter(Mandatory=$true)]
    [string]$AdministratorPassword,

    [string]$DomainName,

    [Parameter(Mandatory=$true)]
    [string]$IPAddress,

    [Parameter(Mandatory=$true)]
    [byte]$PrefixLength,
    
    [Parameter(Mandatory=$true)]
    [string]$DefaultGateway,
    
    [string[]]$DnsAddresses = @('8.8.8.8','8.8.4.4'),

    [ValidateSet('Public', 'Private')]
    [string]$NetworkCategory = 'Public'
)

    if ($DomainName) {
        $userName = "$DomainName\administrator"
    } else {
        $userName = 'administrator'
    }
    $pass = ConvertTo-SecureString $AdministratorPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($userName, $pass)
    
    $sleep_counter = 0
    do {
        $session = New-PSSession -VMName $VMName -Credential $cred -ErrorAction SilentlyContinue
    
        if (-not $session) {
            $sleep_counter++
            Write-Verbose "Waiting for connection with '$VMName'..."
            Start-Sleep -Seconds 1
        }
    } while (-not $session -And $sleep_counter -lt 720) #Wait 10 mins at most

    Invoke-Command -Session $session { 
        Remove-NetRoute -NextHop $using:DefaultGateway -Confirm:$false -ErrorAction SilentlyContinue
        $neta = Get-NetAdapter 'Ethernet'        # Use the exact adapter name for multi-adapter VMs
 #       $neta | Set-NetConnectionProfile -NetworkCategory $using:NetworkCategory
        $neta | Set-NetIPInterface -Dhcp Disabled
        $neta | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false 
    
        # New-NetIPAddress may fail for certain scenarios (e.g. PrefixLength = 32). Using netsh instead.
        $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $using:PrefixLength) -shr (32 - $using:PrefixLength))
        netsh interface ipv4 set address name="$($neta.InterfaceAlias)" static $using:IPAddress $mask.IPAddressToString $using:DefaultGateway
    
        $neta | Set-DnsClientServerAddress -Addresses $using:DnsAddresses
    } | Out-Null

    Invoke-Command -Session $session { 
        # Enable remote administration
        Enable-PSRemoting -SkipNetworkProfileCheck -Force
        Enable-WSManCredSSP -Role server -Force
    
        # Default rule is for 'Local Subnet' only. Change to 'Any'.
        Set-NetFirewallRule -DisplayName 'Windows Remote Management (HTTP-In)' -RemoteAddress Any
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    } | Out-Null

    Remove-PSSession $session

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

try {
    $params = Parse-Args -arguments $args -supports_check_mode $true
    $check_mode = Get-AnsibleParam -obj $params -name "_ansible_check_mode" -type "bool" -default $false
    $state = Get-AnsibleParam -obj $params -name "state" -type "str" -default "present" -validateset "absent", "present"
    $version = Get-AnsibleParam -obj $params -name "version" -type "str" -default "Server2016Datacenter" -validateset "Server2016Datacenter", "Server2016Standard"
    $vm_name = Get-AnsibleParam -obj $params -name "vm_name" -type "str" -failifempty $true
    $admin_password = Get-AnsibleParam -obj $params -name "admin_password" -type "str" -failifempty $true
    $iso_origin =  Get-AnsibleParam -obj $params -name "iso_origin" -type "str" -failifempty $true
    $vhdx_size_bytes = Get-AnsibleParam -obj $params -name "vhdx_size_bytes" -type "uint64" -default 50GB
    $destination_volume = Get-AnsibleParam -obj $params -name "destination_volume" -type "str" -failifempty $true
    $switch_name = Get-AnsibleParam -obj $params -name "switch_name" -type "str" -failifempty $true
    $ip_address = Get-AnsibleParam -obj $params -name "ip_address" -type "str" -failifempty $true
    $gateway = Get-AnsibleParam -obj $params -name "gateway" -type "str" -failifempty $true
    $dns_addresses = Get-AnsibleParam -obj $params -name "dns_addresses" -type "list" -failifempty $true
    $memory_startup_bytes = Get-AnsibleParam -obj $params -name "memory_startup_bytes" -type "uint64" -default 2GB
    $enable_dynamic_memory = Get-AnsibleParam -obj $params -name "enable_dynamic_memory" -type "bool" -default $true
    $vlan_id = Get-AnsibleParam -obj $params -name "vlan_id" -type "str" -failifempty $true
    $processor_count = 2
    $mac_address = Get-AnsibleParam -obj $params -name "mac_address" -type "str"
    $edition = Get-AnsibleParam -obj $params -name "edition" -type "str" -default "ServerDatacenter"

    $ErrorActionPreference = 'Stop'

    # Get default VHD path (requires administrative privileges)
    $vmms = gwmi -namespace root\virtualization\v2 Msvm_VirtualSystemManagementService
    $vmmsSettings = gwmi -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData

    $destination_volume = $destination_volume.trimend('\')
    $destinationFolder = "$destination_volume\$vm_name".trimend('\')
    $vhdPath ="$destinationFolder\Virtual Hard Disk" 
    $vmPath = "$destinationFolder\Virtual Machines"
    $vhdxPath = "$vhdPath\$($vm_name)_os.vhdx"

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

    # Create unattend.xml
    $unattendPath = New-WindowsUnattendFile -AdministratorPassword $admin_password -Version $version -ComputerName $vm_name -Locale "en-US"
    # Create VHDX from ISO image
    Write-Verbose 'Creating VHDX from image...'
    Convert-WindowsImageNew -SourcePath $iso_origin -Edition $edition -VHDPath $vhdxPath -SizeBytes $vhdx_size_bytes -VHDFormat VHDX -DiskLayout UEFI -UnattendPath $unattendPath
    # Create VM
    Write-Verbose 'Creating VM...'
    $vm = New-VM -Name $vm_name -Generation 2  -MemoryStartupBytes $memory_startup_bytes -VHDPath $vhdxPath -Path $vmPath -SwitchName $switch_name
    $vm | Set-VMProcessor -Count $processor_count
    $vm | Get-VMIntegrationService -Name "Guest Service Interface" | Enable-VMIntegrationService
    if ($enable_dynamic_memory) {
        $vm | Set-VMMemory -DynamicMemoryEnabled $true 
    }
    if ($mac_address) {
        $vm | Set-VMNetworkAdapter -StaticMacAddress ($mac_address -replace ':','')
    }
    # Disable Automatic Checkpoints (doesn't exist in Server 2016)
    $command = Get-Command Set-VM
    if ($command.Parameters.AutomaticCheckpointsEnabled) {
        $vm | Set-VM -AutomaticCheckpointsEnabled $false
    }
    $eth0 = Get-VMNetworkAdapter -VMName $vm_name 
    # Set VLAN ID
    $eth0 | Set-VMNetworkAdapterVlan -VlanID $vlan_id -Access

    $vm | Start-VM

    # Wait for installation complete
    Write-Verbose 'Waiting for VM integration services...'
    Wait-VM -Name $vm_name -For Heartbeat

    $vm | Add-ClusterVirtualMachineRole

    Start-Sleep -Seconds 30 #Wait 30 secs for a boot
    
    Invoke-Bootstrap-VM -VMName $vm_name -AdministratorPassword $admin_password -IPAddress $ip_address -PrefixLength 24 -DefaultGateway $gateway -DnsAddresses $dns_addresses -NetworkCategory 'Public'

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
