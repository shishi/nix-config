# dns-osaka-1 の OCI 資源を宣言する。既存資源の import が前提で、この構成から
# 新規作成しない。認証は ~/.oci/config(API 署名鍵)。実行は OpenTofu を使う。
#
#   tofu init
#   tofu plan   # 合格条件: No changes(instance の create/delete/replace が出たら停止)
#
# Public IPv4 (129.225.177.221) は EPHEMERAL で VNIC に従属するため資源として
# 管理しない(VNIC を作り直すと変わる)。Boot Volume も instance 従属で管理外。

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }
}

provider "oci" {
  # Console が付ける作成監査タグは構成で管理しない
  ignore_defined_tags = ["Oracle-Tags.CreatedBy", "Oracle-Tags.CreatedOn"]
}

locals {
  # Always Free tenancy のため compartment は root(tenancy)そのもの
  compartment_id = "ocid1.tenancy.oc1..aaaaaaaammil3ivtxoru7ho3cxc5bfj4y2ia75loyfgtgl27dg2pb5u3ql4a"
}

import {
  to = oci_core_vcn.this
  id = "ocid1.vcn.oc1.ap-osaka-1.amaaaaaae2wro5aamhep77a2eclzyo4o6fun7ppo6ezbzbf5zahgjdexvkbq"
}

resource "oci_core_vcn" "this" {
  compartment_id = local.compartment_id
  display_name   = "vcn-20260728-1202"
  dns_label      = "vcn07281224"
  cidr_blocks    = ["10.0.0.0/16"]
  is_ipv6enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = oci_core_internet_gateway.this
  id = "ocid1.internetgateway.oc1.ap-osaka-1.aaaaaaaaimt2igrlhz5bwbb5oh63o5wu2oyfndtoygt5wkbyik2dmqoj6raa"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "Internet Gateway vcn-20260728-1202"
  enabled        = true

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = oci_core_default_route_table.this
  id = "ocid1.routetable.oc1.ap-osaka-1.aaaaaaaa7w2kvkt644wceyvjub5bfc4vq33gnmwv6qr25hbvmi3xvvukvl7q"
}

resource "oci_core_default_route_table" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_route_table_id
  compartment_id             = local.compartment_id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  route_rules {
    destination       = "::/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = oci_core_default_security_list.this
  id = "ocid1.securitylist.oc1.ap-osaka-1.aaaaaaaat5fqiwvc5stniyb5bwdojpdcffssj4dajhlb7ul7jhilp3htbnpq"
}

resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  compartment_id             = local.compartment_id

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  egress_security_rules {
    destination      = "::/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  # Public SSH(Tailscale 停止時の唯一の入口)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMP: 経路 MTU 探索(v4 は type3/code4、VCN 内は type3 全般、v6 は全 ICMPv6)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = "10.0.0.0/16"
    icmp_options {
      type = 3
    }
  }

  ingress_security_rules {
    protocol = "58"
    source   = "::/0"
  }

  # Tailscale の WireGuard 直結(無いと中継経由で遅くなる)
  ingress_security_rules {
    description = "Tailscale direct P2P (WireGuard)"
    protocol    = "17"
    source      = "0.0.0.0/0"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  ingress_security_rules {
    description = "Tailscale direct P2P (WireGuard)"
    protocol    = "17"
    source      = "::/0"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = oci_core_subnet.this
  id = "ocid1.subnet.oc1.ap-osaka-1.aaaaaaaa3k572xanidofn3heukmqzynraokk4vggoo7y4h4w53ytxgvnfuoq"
}

resource "oci_core_subnet" "this" {
  compartment_id    = local.compartment_id
  vcn_id            = oci_core_vcn.this.id
  display_name      = "subnet-20260728-1202"
  dns_label         = "subnet07281224"
  cidr_block        = "10.0.0.0/24"
  route_table_id    = oci_core_default_route_table.this.id
  security_list_ids = [oci_core_default_security_list.this.id]
  # VCN の /56 から下位 8 bit = 00 を切った /64
  ipv6cidr_blocks = ["2603:c023:16:4100::/64"]

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = oci_core_instance.this
  id = "ocid1.instance.oc1.ap-osaka-1.anvwsljre2wro5acztzy2gaq462solq62vhojqexb27eiejpeik3zbfj455a"
}

resource "oci_core_instance" "this" {
  compartment_id      = local.compartment_id
  availability_domain = "WmZe:AP-OSAKA-1-AD-1"
  fault_domain        = "FAULT-DOMAIN-3"
  display_name        = "dns-osaka-1"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  source_details {
    source_type = "image"
    # Ubuntu 24.04 aarch64(nixos-anywhere で NixOS へ置換済み。ここは
    # 作成時イメージの記録で、変更すると replace になるため触らない)
    source_id = "ocid1.image.oc1.ap-osaka-1.aaaaaaaalbmosmrdhytl6c3f3mtqi7ihlbzn324b6frshw3f2fs2ouragd6a"
  }

  create_vnic_details {
    subnet_id      = oci_core_subnet.this.id
    hostname_label = "dns-osaka-1"
    display_name   = "dns-osaka-1"
  }

  metadata = {
    ssh_authorized_keys = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILarf1PUuzo6XLQNwnOf2IZeyCqXGxgNdrSJUjgbp/94"
  }

  # Always Free A1 の idle 回収判定に使われる Monitoring は必ず有効を維持する
  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false

    plugins_config {
      name          = "Vulnerability Scanning"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "OS Management Hub Agent"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Management Agent"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Custom Logs Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Compute RDMA GPU Monitoring"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Compute HPC RDMA Auto-Configuration"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Compute HPC RDMA Authentication"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Cloud Guard Workload Protection"
      desired_state = "ENABLED"
    }
    plugins_config {
      name          = "Block Volume Management"
      desired_state = "DISABLED"
    }
    plugins_config {
      name          = "Bastion"
      desired_state = "DISABLED"
    }
  }

  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}
