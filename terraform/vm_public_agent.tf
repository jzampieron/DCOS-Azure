#
# This is a terraform script to provision the DC/OS public agent nodes.
#
# Copyright (c) 2017 by Beco, Inc. All rights reserved.
#
# Created July-2017 by Jeffrey Zampieron <jeff@beco.io>
#
# License: See included LICENSE.md
#

# The first network interface for the public agents
resource "azurerm_network_interface" "dcosPublicAgentIF0" {
    name                    = "dcosPublicAgentIF${count.index}-0"
    location                = "${azurerm_resource_group.dcos.location}"
    resource_group_name     = "${azurerm_resource_group.dcos.name}"
    // JZ - Disabled b/c you can't mix AN and non-AN VMs in the same avail. set
    // Would require a complete cluster rebuild.
    //enable_accelerated_networking = "${lookup( var.vm_type_to_an, var.agent_public_size, "false" )}"
    count                   = "${var.agent_public_count}"

    ip_configuration {
        name                                    = "publicAgentIPConfig"
        subnet_id                               = "${azurerm_subnet.dcospublic.id}"
        private_ip_address_allocation           = "static"
        private_ip_address                      = "10.0.${count.index / 254}.${ (count.index + 10) % 254 }"
        load_balancer_backend_address_pools_ids = ["${azurerm_lb_backend_address_pool.agent_public.id}"]
        #NO PUBLIC IP FOR THIS INTERFACE - VM ONLY ACCESSIBLE INTERNALLY
        #public_ip_address_id          = "${azurerm_public_ip.vmPubIP.id}"
    }
}

resource "azurerm_network_interface" "dcosPublicAgentMgmt" {
    name                = "dcosPublicAgentMgmtIF${count.index}-0"
    location            = "${azurerm_resource_group.dcos.location}"
    resource_group_name = "${azurerm_resource_group.dcos.name}"
    // JZ - Disabled b/c you can't mix AN and non-AN VMs in the same avail. set
    // Would require a complete cluster rebuild.
    //enable_accelerated_networking = "${lookup( var.vm_type_to_an, var.agent_public_size, "false" )}"
    count               = "${var.agent_public_count}"

    ip_configuration {
        name                                    = "publicAgentMgMtIPConfig"
        subnet_id                               = "${azurerm_subnet.dcosMgmt.id}"
        private_ip_address_allocation           = "static"
        private_ip_address                      = "10.65.${count.index / 254}.${ (count.index + 10) % 254 }"
    }
}

resource "azurerm_virtual_machine" "dcosPublicAgent" {
    name                          = "dcospublicagent${count.index}"
    location                      = "${azurerm_resource_group.dcos.location}"
    resource_group_name           = "${azurerm_resource_group.dcos.name}"
    primary_network_interface_id  = "${ azurerm_network_interface.dcosPublicAgentIF0.*.id[ count.index ] }"
    network_interface_ids         = [ "${ azurerm_network_interface.dcosPublicAgentIF0.*.id[ count.index ] }",
        "${ azurerm_network_interface.dcosPublicAgentMgmt.*.id[ count.index ] }" ]
    vm_size                       = "${var.agent_public_size}"
    availability_set_id           = "${azurerm_availability_set.publicAgentVMAvailSet.id}"
    delete_os_disk_on_termination    = true
    delete_data_disks_on_termination = true
    count                         = "${var.agent_public_count}"
    depends_on                    = ["azurerm_virtual_machine.master"]

    lifecycle {
        ignore_changes  = ["admin_password"]
    }

    connection {
        type         = "ssh"
        host         = "${ azurerm_network_interface.dcosPublicAgentIF0.*.private_ip_address[ count.index ] }"
        user         = "${var.vm_user}"
        timeout      = "120s"
        private_key  = "${file(var.private_key_path)}"
        # Configuration for the Jumpbox
        bastion_host        = "${azurerm_public_ip.dcosBootstrapNodePublicIp.ip_address}"
        bastion_user        = "${var.vm_user}"
        bastion_private_key = "${file(var.bootstrap_private_key_path)}"
    }

    # provisioners execute in order.
    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p /opt/dcos",
            "sudo chown ${var.vm_user} /opt/dcos",
            "sudo chmod 755 -R /opt/dcos"
        ]
    }

    # Provision the VM itself.
    provisioner "file" {
        source      = "${path.module}/files/vm_setup.sh"
        destination = "/opt/dcos/vm_setup.sh"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo chmod 755 /opt/dcos/vm_setup.sh",
            "sudo /opt/dcos/vm_setup.sh"
        ]
    }

    # Now the provisioning for DC/OS
    provisioner "file" {
        source      = "${path.module}/files/install.sh"
        destination = "/opt/dcos/install.sh"
    }

    provisioner "file" {
        source      = "${path.module}/files/50-docker.network"
        destination = "/tmp/50-docker.network"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo mv /tmp/50-docker.network /etc/systemd/network/",
            "sudo chmod 644 /etc/systemd/network/50-docker.network",
            "sudo systemctl restart systemd-networkd",
            "chmod 755 /opt/dcos/install.sh",
            "cd /opt/dcos && bash install.sh '172.16.0.8' 'slave_public'"
        ]
    }

    boot_diagnostics {
        enabled     = true
        storage_uri = "${azurerm_storage_account.dcos.primary_blob_endpoint}"
    }

    storage_image_reference {
        publisher = "${var.image["publisher"]}"
        offer     = "${var.image["offer"]}"
        sku       = "${var.image["sku"]}"
        version   = "${var.image["version"]}"
    }

    storage_os_disk {
        name              = "dcosPublicAgentOsDisk${count.index}"
        caching           = "ReadWrite"
        create_option     = "FromImage"
        managed_disk_type = "${lookup( var.vm_type_to_os_disk_type, var.agent_public_size, "Premium_LRS" )}"
        disk_size_gb      = "${var.os_disk_size}"
    }

    /**
     * These extra disks ensure that the synchronous write load from ZK and etcd and other places
     * do not cause other problems with the cluster.
     *
     * A more aggressive configuration would be to split the ZK and etcd WAL
     * drives out as well.
     */

    # Storage for /var/log
    storage_data_disk {
        name              = "dcosPublicLogDisk-${count.index}"
        caching           = "None"
        create_option     = "Empty"
        managed_disk_type = "${ lookup( var.vm_type_to_os_disk_type, var.agent_private_size, "Premium_LRS" ) }"
        disk_size_gb      = "${var.io_offload_disk_size}"
        lun               = 1
    }

    # Storage for /var/lib/docker
    storage_data_disk {
        name              = "dcosPublicDockerDisk-${count.index}"
        caching           = "ReadOnly"
        create_option     = "Empty"
        managed_disk_type = "${ lookup( var.vm_type_to_os_disk_type, var.agent_private_size, "Premium_LRS" ) }"
        disk_size_gb      = "${var.io_offload_disk_size}"
        lun               = 2
    }

    # Storage for /var/lib/mesos/slave
    storage_data_disk {
        name              = "dcosPublicMesosDisk-${count.index}"
        caching           = "ReadOnly"
        create_option     = "Empty"
        managed_disk_type = "${ lookup( var.vm_type_to_os_disk_type, var.agent_private_size, "Premium_LRS" ) }"
        disk_size_gb      = "${var.mesos_slave_disk_size}"
        lun               = 3
    }

    os_profile {
        computer_name  = "dcospublicagent${count.index}"
        admin_username = "${var.vm_user}"
        admin_password = "${uuid()}"
        # According to the Azure Terraform Documentation
        # and https://docs.microsoft.com/en-us/azure/virtual-machines/linux/using-cloud-init
        # Cloud init is supported on ubuntu and coreos for custom_data.
        # However, according to CoreOS, their Ignition format is preferred.
        # cloud-init on Azure appears to be the deprecated coreos-cloudinit
        # Therefore we are going to try ignition.
        custom_data    = "${ data.ignition_config.public_agent.*.rendered[ count.index ] }"
    }

    os_profile_linux_config {
        disable_password_authentication = true
        ssh_keys {
            path     = "/home/${var.vm_user}/.ssh/authorized_keys"
            key_data = "${file(var.public_key_path)}"
        }
    }

    tags {
        environment = "${var.instance_name}"
    }

}

# Setup an Azure VM Extension for Monitoring
# See: https://docs.microsoft.com/en-us/azure/virtual-machines/linux/diagnostic-extension
# for details.
#az vm extension set --publisher Microsoft.Azure.Diagnostics --name LinuxDiagnostic --version 3.0
# --resource-group $my_resource_group --vm-name $my_linux_vm
# --protected-settings "${my_lad_protected_settings}" --settings portal_public_settings.json
/*
# JZ - This is on HOLD b/c of https://github.com/terraform-providers/terraform-provider-azurerm/issues/59
# i.e. there isn't a way to get a SAS token in Terraform right now.
data "template_file" "public_agent_lad_settings" {
  template = "${file( "${path.module}/files/lad_settings.json.tpl" )}"
  count    = "${var.agent_public_count}"
  vars = {
    DIAGNOSTIC_STORAGE_ACCOUNT = "${azurerm_storage_account.dcosAzureLinuxDiag.name}"
    VM_RESOURCE_ID             = "${( azurerm_virtual_machine.dcosPublicAgent.*.id, count.index )}"
  }
}

resource "azurerm_virtual_machine_extension" "dcosPublicAgentDiagExt" {
  name                        = "dcosPublicAgentDiagExt"
  location                    = "${azurerm_resource_group.dcos.location}"
  resource_group_name         = "${azurerm_resource_group.dcos.name}"
  virtual_machine_name        = "${( azurerm_virtual_machine.dcosPublicAgent.*.name, count.index )}"
  publisher                   = "Microsoft.Azure.Diagnostics"
  type                        = "LinuxDiagnostic"
  type_handler_version        = "3.0"
  auto_upgrade_minor_version  = true
  count                       = "${var.agent_public_count}"

  # see: https://docs.microsoft.com/en-us/azure/virtual-machines/linux/diagnostic-extension
  protected_settings = <<PROTSETTINGS
  {
    "storageAccountName" : "${azurerm_storage_account.dcosAzureLinuxDiag.name}",
    "storageAccountEndPoint": "",
    "storageAccountSasToken": "SAS access token",
  }
PROTSETTINGS

  settings = "${( data.template_file.public_agent_lad_settings.*.rendered, count.index )}"

  tags = {
    environment = "${var.instance_name}"
  }
}
*/
