##################################################
# Create and attach block storage to worker nodes
##################################################

# Determine every worker's zone
data ibm_resource_group group {
  name = var.resource_group_name
}

data ibm_container_vpc_cluster this{
  count = var.enable ? 1 : 0
  name = var.cluster_id
  resource_group_id = data.ibm_resource_group.group.id
}

data "ibm_container_vpc_cluster_worker" "this" {
  count = var.enable ? var.worker_nodes : 0

  cluster_name_id   = var.cluster_id
  resource_group_id = data.ibm_resource_group.group.id
  worker_id         = length(data.ibm_container_vpc_cluster.this) > 0 ? data.ibm_container_vpc_cluster.this[0].workers[count.index] : 0
}

data "ibm_iam_auth_token" "this" {}

# ibm_is_subnet is currently bugged. On a run, it can error with an expired or bad token. A subsequent rerun fixes this, 
# but this script should run the first time without any problems.
data "ibm_is_subnet" "this" {
  count = var.enable ? var.worker_nodes : 0
  identifier = length(data.ibm_container_vpc_cluster_worker.this) > 0 ? data.ibm_container_vpc_cluster_worker.this[count.index].network_interfaces[0].subnet_id : 0
}

# data "external" "get_zone_from_subnet" {
#   count = var.enable ? var.worker_nodes : 0
#   depends_on = [
#     data.ibm_container_vpc_cluster_worker.this,
#     data.ibm_iam_auth_token.this
#   ]

#   program = ["/bin/bash", "${path.module}/scripts/get_zone_from_subnet.sh"]

#   query = {
#     region     = var.region
#     identifier = data.ibm_container_vpc_cluster_worker.this[count.index].network_interfaces[0].subnet_id
#     token      = data.ibm_iam_auth_token.this.iam_access_token
#   }
# }

# Create a block storage volume per worker.
resource "ibm_is_volume" "this" {
  depends_on = [
    data.ibm_is_subnet.this
  ]

  count = var.enable && var.install_storage ? var.worker_nodes : 0 
  
  capacity = var.storage_capacity
  iops = var.storage_profile == "custom" ? var.storage_iops : null
  name = length(data.ibm_container_vpc_cluster.this) > 0 ? "${var.unique_id}-pwx-${split("-", data.ibm_container_vpc_cluster.this[0].workers[count.index])[4]}" : "${var.unique_id}-pwx"
  profile = var.storage_profile
  resource_group = data.ibm_resource_group.group.id
  zone = length(data.ibm_is_subnet.this) > 0 ? data.ibm_is_subnet.this[count.index].zone : ""
}

# locals {
#   worker_volume_map = zipmap(data.ibm_container_vpc_cluster_worker.this.*.id, ibm_is_volume.this.*.id)
# }

# Attach block storage to worker
resource "null_resource" "volume_attachment" {
  # count = length(data.ibm_container_vpc_cluster_worker.worker)
  count = var.enable && var.install_storage ? var.worker_nodes : 0 

  depends_on = [
    ibm_is_volume.this,
  ]
  # for_each = local.worker_volume_map
  
  triggers = {
    volume = length(ibm_is_volume.this) > 0 ? ibm_is_volume.this[count.index].id : 0
    worker = length(data.ibm_container_vpc_cluster_worker.this) > 0 ? data.ibm_container_vpc_cluster_worker.this[count.index].id : 0
  }

  provisioner "local-exec" {
    environment = {
      IBMCLOUD_API_KEY  = var.ibmcloud_api_key
      TOKEN             = data.ibm_iam_auth_token.this.iam_access_token
      REGION            = var.region
      RESOURCE_GROUP_ID = data.ibm_resource_group.group.id
      CLUSTER_ID        = var.cluster_id
      WORKER_ID         = length(data.ibm_container_vpc_cluster_worker.this) > 0 ? data.ibm_container_vpc_cluster_worker.this[count.index].id : 0
      VOLUME_ID         = length(ibm_is_volume.this) > 0 ? ibm_is_volume.this[count.index].id : 0
    }

    interpreter = ["/bin/bash", "-c"]
    command     = file("${path.module}/scripts/volume_attachment.sh")
  }

#############################################
# Create 'Databases for Etcd' service instance
#############################################
resource "ibm_database" "etcd" {
  count = var.enable && var.create_external_etcd ? 1 : 0
  location = var.region
  members_cpu_allocation_count = 9
  members_disk_allocation_mb = 393216
  members_memory_allocation_mb = 24576
  name = "${var.unique_id}-pwx-etcd"
  plan = "standard"
  resource_group_id = data.ibm_resource_group.group.id
  service = "databases-for-etcd"
  service_endpoints = "private"
  version = "3.3"
  users {
    name = var.etcd_username
    password = var.etcd_password
  }
}

# find the object in the connectionstrings list in which the `name` is var.etcd_username
locals {
  ibm_operator_catalog              = file(join("/", [path.module, "files", "subscription-ocs-subscription.yaml"]))
  subscription                      = file(join("/", [path.module, "files", "subscription.yaml"])) 
  operator_group                    = file(join("/", [path.module, "files", "operator-group.yaml"])) 

  etcd_user_connectionstring = (var.create_external_etcd ?
                                ibm_database.etcd[0].connectionstrings[index(ibm_database.etcd[0].connectionstrings[*].name, var.etcd_username)] :
                                null)
}

resource "kubernetes_secret" "etcd" {
  count = var.enable && var.create_external_etcd ? 1 : 0
  
  metadata {
    name = var.etcd_secret_name
    namespace = "kube-system"
  }

  data = {
    "ca.pem" = base64decode(local.etcd_user_connectionstring.certbase64)
    username = var.etcd_username
    password = var.etcd_password
  }
  
}

##################################
# Install ODF on the cluster
##################################

resource "null_resource" "install_cp4d_operator" {
  count = var.enable ? 1 : 0

  triggers = {
    namespace_sha1                            = sha1(local.namespace)
    docker_params_sha1                        = sha1(join("", [var.entitled_registry_user_email, local.entitled_registry_key]))
    ibm_operator_catalog_sha1                 = sha1(local.ibm_operator_catalog)
    opencloud_operator_catalog_sha1           = sha1(local.opencloud_operator_catalog)
    subscription_sha1                         = sha1(local.subscription)
    operator_group_sha1                       = sha1(local.operator_group)
  }

  provisioner "local-exec" {
    command     = "./install_odf.sh"
    working_dir = "${path.module}/scripts"

    environment = {
      KUBECONFIG                    = var.cluster_config_path
      NAMESPACE                     = var.cpd_project_name
      IBM_OPERATOR_CATALOG          = local.ibm_operator_catalog
      OPENCLOUD_OPERATOR_CATALOG    = local.opencloud_operator_catalog
      SUBSCRIPTION                  = local.subscription
      DOCKER_REGISTRY_PASS          = local.entitled_registry_key
      DOCKER_USER_EMAIL             = var.entitled_registry_user_email
      DOCKER_USERNAME               = local.docker_username
      DOCKER_REGISTRY               = local.docker_registry
      OPERATOR_GROUP                = local.operator_group
    }
  }

  depends_on = [
    local.on_vpc_ready, // Something needs to be done here... perhaps on_vpc check?
    null_resource.prereqs_checkpoint
  ]
}

# resource "ibm_resource_instance" "portworx" {
#   depends_on = [
#     null_resource.volume_attachment,
#     kubernetes_secret.etcd,
#   ]

#   count = var.enable ? 1 : 0

#   name              = "${var.unique_id}-pwx-service"
#   service           = "portworx"
#   plan              = "px-enterprise"
#   location          = var.region
#   resource_group_id = data.ibm_resource_group.group.id

#   tags = [
#     "clusterid:${var.cluster_id}",
#   ]

#   parameters = {
#     apikey           = var.ibmcloud_api_key
#     cluster_name     = "pwx"
#     clusters         = var.cluster_id
#     etcd_endpoint    = ( var.create_external_etcd ?
#       "etcd:https://${local.etcd_user_connectionstring.hosts[0].hostname}:${local.etcd_user_connectionstring.hosts[0].port}"
#       : null
#     )
#     etcd_secret      = var.create_external_etcd ? var.etcd_secret_name : null
#     internal_kvdb    = var.create_external_etcd ? "external" : "internal"
#     portworx_version = "Portworx: 2.6.2.1 , Stork: 2.6.0"
#     secret_type      = "k8s"
#   }

#   provisioner "local-exec" {
#     environment = {
#       KUBECONFIG = var.kube_config_path
#     }
#     interpreter = ["/bin/bash", "-c"]
#     command     = file("${path.module}/scripts/portworx_wait_until_ready.sh")
#   }
#   /*
#   #
#   # Currently, deleting the portworx service instance does not uninstall portworx
#   # from the cluster.
#   #
#   */
# }