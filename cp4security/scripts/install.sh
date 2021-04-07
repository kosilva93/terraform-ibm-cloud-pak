#!/bin/bash

echo 
echo "Running CP4S Install"
echo 

export I_PWD=$(pwd)

if [ -z $1 ]
then
  source ./environment_variables.sh
else
  echo $1 file used
  source ./$1
fi

if [ -z "$OCP_TOKEN" ]
then
    oc login --token=$OCP_PASSWORD --server=https://$OCP_URL
else
    oc login -u apikey -p $OCP_TOKEN --server=https://$OCP_URL
fi


rm -rf cp4s-15
cloudctl case save --case https://github.com/IBM/cloud-pak/raw/master/repo/case/ibm-cp-security-1.0.15.tgz --outputdir cp4s-15 --tolerance 1

rm -rf ibm-cp-security
tar xf cp4s-15/ibm-cp-security-1.0.15.tgz

function self-signed {
cat << EOF  > ibm-cp-security/inventory/installProduct/files/values.conf

# Admin User ID (Required)
adminUserId="$PLATFORM_ADMIN" 

#Cluster type e.g aws,ibmcloud, ocp (Required)
cloudType="$CLUSTER_PLATFORM"

# CP4S FQDN domain(Required)
cp4sapplicationDomain="$CP4S_FQDN"

# e.g ./path-to-cert/cert.crt (Required)
cp4sdomainCertificatePath="./domain-cert.crt" 

## Path to domain certificate key ./path-to-key/cert.key (Required)
cp4sdomainCertificateKeyPath="./private.key"  

# Path to custom ca cert e.g <path-to-cert>/ca.crt (Only required if using custom/self signed certificate)
cp4scustomcaFilepath="./ca.crt" 

# Set image pullpolicy  e.g Always,IfNotPresent, default is IfNotPresent (Optional)
cp4simagePullPolicy="IfNotPresent"

# Set to "true" to enable Openshift authentication. Only supported for ROKS clusters. (Optional)
cp4sOpenshiftAuthentication="false"

# Default Account name, default is "Cloud Pak For Security" (Optional)
#defaultAccountName="Cloud Pak For Security" 

# set to "true" to enable CSA Adapter (Optional)
enableCloudSecurityAdvisor="false" 

## Only Required for online install 
entitledRegistryUrl="$ENTITLED_REGISTRY_URL"

## Only Required for online install 
entitledRegistryPassword="$ENTITLED_REGISTRY_PASSWORD" 

## Only Required for online install 
entitledRegistryUsername="$ENTITLED_REGISTRY_USERNAME" 

# Only required for airgap install
localDockerRegistry="" 

# Only required for airgap install
localDockerRegistryUsername=""

# Only required for airgap install
localDockerRegistryPassword=""

#Entitled by default,set to <local> for airgap install 
registryType="entitled"

# Block storage (Required)
storageClass="$STORAGE_CLASS"

# Set storage fs group. Default is 26 (Optional)
storageClassFsGroup="26"

# Set storage class supplemental groups (Optional)
storageClassSupplementalGroups="" 

# set seperate storageclass for toolbox (Optional)
toolboxStorageClass="" 

# set custom storage size for toolbox,default is 100Gi (Optional)
toolboxStorageSize="100Gi" 

EOF
}

function not-self-signed {
cat << EOF  > ibm-cp-security/inventory/installProduct/files/values.conf

# Admin User ID (Required)
adminUserId="$PLATFORM_ADMIN" 

#Cluster type e.g aws,ibmcloud, ocp (Required)
cloudType="$CLUSTER_PLATFORM"

# CP4S FQDN domain(Required)
cp4sapplicationDomain="$CP4S_FQDN"

# e.g ./path-to-cert/cert.crt (Required)
cp4sdomainCertificatePath="./domain-cert.crt" 

## Path to domain certificate key ./path-to-key/cert.key (Required)
cp4sdomainCertificateKeyPath="./private.key"  

# Path to custom ca cert e.g <path-to-cert>/ca.crt (Only required if using custom/self signed certificate)
cp4scustomcaFilepath="" 

# Set image pullpolicy  e.g Always,IfNotPresent, default is IfNotPresent (Optional)
cp4simagePullPolicy="IfNotPresent"

# Set to "true" to enable Openshift authentication. Only supported for ROKS clusters. (Optional)
cp4sOpenshiftAuthentication="false"

# Default Account name, default is "Cloud Pak For Security" (Optional)
#defaultAccountName="Cloud Pak For Security" 

# set to "true" to enable CSA Adapter (Optional)
enableCloudSecurityAdvisor="false" 

## Only Required for online install 
entitledRegistryUrl="$ENTITLED_REGISTRY_URL"

## Only Required for online install 
entitledRegistryPassword="$ENTITLED_REGISTRY_PASSWORD" 

## Only Required for online install 
entitledRegistryUsername="$ENTITLED_REGISTRY_USERNAME" 

# Only required for airgap install
localDockerRegistry="" 

# Only required for airgap install
localDockerRegistryUsername=""

# Only required for airgap install
localDockerRegistryPassword=""

#Entitled by default,set to <local> for airgap install 
registryType="entitled"

# Block storage (Required)
storageClass="$STORAGE_CLASS"

# Set storage fs group. Default is 26 (Optional)
storageClassFsGroup="26"

# Set storage class supplemental groups (Optional)
storageClassSupplementalGroups="" 

# set seperate storageclass for toolbox (Optional)
toolboxStorageClass="" 

# set custom storage size for toolbox,default is 100Gi (Optional)
toolboxStorageSize="100Gi" 

EOF
}

if $SELF_SIGNED_CERT
then
  self-signed
else
  not-self-signed
fi

echo
cat ibm-cp-security/inventory/installProduct/files/values.conf
echo

echo cloudctl case launch
echo
cloudctl case launch --case ibm-cp-security --namespace cp4s  --inventory installProduct --action install --args "--license accept --helm3 /usr/local/bin/helm3 --inputDir cp4s-15/" --tolerance 1
echo

echo 
echo "CP4S Install completed"
echo 

function install-openldap {
echo Installing openldap:
echo

CP_PASSWORD=$(oc get secret platform-auth-idp-credentials -o jsonpath='{.data.admin_password}' -n ibm-common-services | base64 -d)
CP_ROUTE=$(oc get route cp-console -n ibm-common-services|awk 'FNR == 2 {print $2}')
SERVER="$(cut -d':' -f1 <<<"$OCP_URL")"
PORT="$(cut -d':' -f2 <<<"$OCP_URL")"

cat << EOF  > ldap/playbook.yml
---
- hosts: local
  gather_facts: true
  any_errors_fatal: true
  roles:
    - roles/secops.ibm.icp.login
    - roles/secops.ibm.icp.openldap.deploy
    - roles/secops.ibm.icp.openldap.register

  vars:
    icp:        
        console_url: "$CP_ROUTE"
        ibm_cloud_server: "$SERVER" # Only Applicable for IBMCloud Deployment
        ibm_cloud_port: "$PORT"   # Only Applicable for IBMCloud Deployment
        username: "admin"
        password: "$CP_PASSWORD"
        account: "id-mycluster-account"
        namespace: "default"

    
    openldap:
        adminPassword: "isc-demo"
        initialPassword: "$LDAP_PASSWORD"
        userlist: "analyst,manager,platform-admin"
EOF

export TILLER_NAMESPACE=ibm-common-services

echo
cat ldap/playbook.yml
echo


echo ansible-playbook -i ldap/hosts ldap/playbook.yml
ansible-playbook -i ldap/hosts ldap/playbook.yml
echo

echo openldap installation complete
}

##########################################################
# Comment out following line to skip openldap installation
install-openldap

echo 
echo "End of script"
echo 