terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.0.0"
    }
  }
}


provider "azurerm" {
  subscription_id = "d055dd42-c99f-4996-a41c-c5eeaae843f3"
  features {}
}

# Create Resource Group
resource "azurerm_resource_group" "myrg" {
  name     = "myrg-resources"
  location = "East US"
}

# Create Virtual Network
resource "azurerm_virtual_network" "mynet" {
  name                = "my-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.myrg.location
  resource_group_name = azurerm_resource_group.myrg.name
}


# Create a Network Security Group (NSG)
resource "azurerm_network_security_group" "mynsg" {
  name                = "my-nsg"
  location            = azurerm_resource_group.myrg.location
  resource_group_name = azurerm_resource_group.myrg.name

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowSSH"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Create Subnet and associate NSG with it
resource "azurerm_subnet" "mysubnet" {
  name                 = "my-subnet"
  resource_group_name  = azurerm_resource_group.myrg.name
  virtual_network_name = azurerm_virtual_network.mynet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Associate NSG with subnet for scaleset
resource "azurerm_subnet_network_security_group_association" "nsg_assoc_vm2" {
  subnet_id                 = azurerm_subnet.mysubnet.id
  network_security_group_id = azurerm_network_security_group.mynsg.id
}

# Create a Public IP for Load Balancer
resource "azurerm_public_ip" "lb_public_ip" {
  name                = "my-lb-public-ip"
  location            = azurerm_resource_group.myrg.location
  resource_group_name = azurerm_resource_group.myrg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}


# Create Load Balancer
resource "azurerm_lb" "mylb" {
  name                = "my-lb"
  location            = azurerm_resource_group.myrg.location
  resource_group_name = azurerm_resource_group.myrg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = azurerm_public_ip.lb_public_ip.id
  }
}

# Create Load Balancer Backend Pool
resource "azurerm_lb_backend_address_pool" "lb_backend_pool" {
  loadbalancer_id = azurerm_lb.mylb.id
  name            = "my-backend-pool"
}

# Create Load Balancer Health Probe
resource "azurerm_lb_probe" "lb_health_probe" {
  loadbalancer_id     = azurerm_lb.mylb.id
  name                = "my-health-probe"
  protocol            = "Http"
  port                = 80
  request_path        = "/"
  interval_in_seconds = 5
  number_of_probes    = 2
}

# Create Load Balancer Rule for HTTP traffic
resource "azurerm_lb_rule" "lb_rule" {
  loadbalancer_id                = azurerm_lb.mylb.id
  name                           = "my-lb-rule"
  protocol                       = "Tcp"
  frontend_ip_configuration_name = "PublicIPAddress"
  frontend_port                  = 80
  backend_port                   = 80
  probe_id                       = azurerm_lb_probe.lb_health_probe.id
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.lb_backend_pool.id] # Reference to backend pool
}

locals {
  custom_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y apache2
    echo "Welcome to - IP: $(hostname -I)" > /var/www/html/index.html
  EOF
}

# Create a Virtual Machine Scale Set (VMSS)
resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                = "my-vmss"
  location            = azurerm_resource_group.myrg.location
  resource_group_name = azurerm_resource_group.myrg.name
  sku                 = "Standard_B1s"
  instances           = 2 # Number of VM instances in the scale set
  upgrade_mode        = "Manual"

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name    = "my-vmss-nic"
    primary = true

    ip_configuration {
      name                                   = "internal"
      subnet_id                              = azurerm_subnet.mysubnet.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.lb_backend_pool.id]
      primary                                = true
    }
  }

  custom_data = base64encode(local.custom_script)

  admin_username = "alam"
  admin_password = "Ahtashamalam@123"

  # Enable password authentication
  disable_password_authentication = false

}


# Autoscaling for Scale Set (Optional)
resource "azurerm_monitor_autoscale_setting" "autoscale" {
  name                = "my-autoscale"
  location            = azurerm_resource_group.myrg.location
  resource_group_name = azurerm_resource_group.myrg.name
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id

  profile {
    name = "autoscaleProfile"

    capacity {
      minimum = "2"
      maximum = "5"
      default = "2"
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        operator           = "GreaterThan"
        statistic          = "Average"
        threshold          = 75
        time_grain         = "PT1M"
        time_window        = "PT5M"
        time_aggregation   = "Average"
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        operator           = "LessThan"
        statistic          = "Average"
        threshold          = 25
        time_grain         = "PT1M"
        time_window        = "PT5M"
        time_aggregation   = "Average"
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }
}
