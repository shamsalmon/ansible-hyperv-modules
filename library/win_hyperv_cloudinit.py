#!/usr/bin/python

DOCUMENTATION='''
'''


EXAMPLES='''
    win_hyperv_cloudinit:
    root_password: toor
    gateway: "10.152.30.1"
    dns_addresses: ["10.152.30.26","10.153.34.26"]
    ip_address: "10.152.30.34/24"
    vm_name: "ENT1MON4"
    fqdn: "ent1mon4.entech.local"
    switch_name: "Admin(30)"
    vhdx_origin: "C:\\ClusterStorage\\Volume70\\ubuntu-cloudimg.vhdx"
    destination_volume: "C:\\ClusterStorage\\Volume70\\"
    vlan_id: 30
    
'''