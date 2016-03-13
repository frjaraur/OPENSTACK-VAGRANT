#!/bin/bash

DEFAULT_PASSWORD=$1
CONTROLLER_IP=$2
CONTROLLER_NAME=$3

echo "DEFAULT_PASSWORD: [${DEFAULT_PASSWORD}]"
echo "CONTROLLER_IP: [${CONTROLLER_IP}]"
echo "CONTROLLER_NAME: [${CONTROLLER_NAME}"

MYSQLCMD="mysql -u root -p${DEFAULT_PASSWORD} -e"

export DEBIAN_FRONTEND=noninteractive

echo "Common OpenStack repository and Software"
apt-get install software-properties-common debconf -y
add-apt-repository -y cloud-archive:liberty
apt-get update -y && apt-get dist-upgrade -y
apt-get install chrony -y &&  service chrony restart
apt-get install python-openstackclient -y


echo "MYSQL/MariaDB"
echo mysql-server mysql-server/root_password password ${DEFAULT_PASSWORD} | debconf-set-selections
echo mysql-server mysql-server/root_password_again password ${DEFAULT_PASSWORD} | debconf-set-selections
#debconf-set-selections <<< 'mysql-server mysql-server/root_password password  ${DEFAULT_PASSWORD}'
#debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password  ${DEFAULT_PASSWORD}'
apt-get install mariadb-server python-pymysql -y
[ $? -ne 0 ] && apt-get -f install -y
mv /tmp/mysqld_openstack.cnf /etc/mysql/conf.d/mysqld_openstack.cnf

echo "Set root password to null to avoid asking for password during install"
service mysql restart
#mysqladmin -u root -p${DEFAULT_PASSWORD} password ''


echo "MongoDB"
apt-get install -y mongodb-server mongodb-clients python-pymongo
if [ -f /etc/mongodb.conf ]
then
  sed -i "s/^bind_ip.*$/bind_ip=${CONTROLLER_IP}/" /etc/mongodb.conf
  sed -i "s/^smallfiles.*$/smallfiles = true/" /etc/mongodb.conf
else
  echo -e "bind_ip=${CONTROLLER_IP}\nsmallfiles = true\n" >/etc/mongodb.conf
fi
service mongodb stop
rm -rf /var/lib/mongodb/journal/prealloc.*
service mongodb start


echo "RabbitMQ"
apt-get install -y rabbitmq-server
rabbitmqctl add_user openstack ${DEFAULT_PASSWORD}
rabbitmqctl set_permissions openstack ".*" ".*" ".*"




# -------------------- KEYSTONE ------------------ #

echo "OPENSTACK KEYSTONE"
${MYSQLCMD} "DROP DATABASE IF EXISTS keystone;"
${MYSQLCMD} "CREATE DATABASE keystone;"
#${MYSQLCMD} "DROP USER IF EXISTS keystone;"
${MYSQLCMD} "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${DEFAULT_PASSWORD}';"
${MYSQLCMD} "GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${DEFAULT_PASSWORD}';"

echo "manual" > /etc/init/keystone.override
apt-get install -y keystone apache2 libapache2-mod-wsgi memcached python-memcache


if [ ! -f /etc/keystone/keystone.random_token ]
then
  ADMIN_TOKEN=$(openssl rand -hex 10)
  echo "Create admin_token file temporaly"
  echo ${ADMIN_TOKEN} >/etc/keystone/keystone.random_token
else
  ADMIN_TOKEN=$(cat /etc/keystone/keystone.random_token)
fi

#BACKUP original  /etc/keystone/keystone.conf file
cp -p  /etc/keystone/keystone.conf  /etc/keystone/keystone.conf.original

cat >/etc/keystone/keystone.conf <<EOF
[DEFAULT]
admin_token = ${ADMIN_TOKEN}
verbose = True

[database]
connection = mysql+pymysql://keystone:${DEFAULT_PASSWORD}@${CONTROLLER_NAME}/keystone

[memcache]
servers = localhost:11211

[token]
provider = uuid
driver = memcache

[revoke]
driver = sql
EOF

#Populate database
su -s /bin/sh -c "keystone-manage db_sync" keystone

rm -f /var/lib/keystone/keystone.db


#BACKUP original /etc/apache2/apache2.conf file
cp -p /etc/apache2/apache2.conf /etc/apache2/apache2.conf.original
if [ $(grep -c ServerName /etc/apache2/apache2.conf) -ne 0 ]
then
  sed -i "s/^ServerName.*$/ServerName ${CONTROLLER_NAME}/" /etc/apache2/apache2.conf
else
  echo "ServerName ${CONTROLLER_NAME}" >> /etc/apache2/apache2.conf
fi
mv /tmp/wsgi-keystone.conf /etc/apache2/sites-available/wsgi-keystone.conf
ln -s /etc/apache2/sites-available/wsgi-keystone.conf /etc/apache2/sites-enabled
service apache2 restart



export OS_TOKEN=${ADMIN_TOKEN}
export OS_URL=http://${CONTROLLER_NAME}:35357/v3
export OS_IDENTITY_API_VERSION=3

echo "OPENSTACK IDENTITY SERVICE"
openstack service create --name keystone --description "OpenStack Identity" identity

echo "OPENSTACK IDENTITY ENDPOINTS"
openstack endpoint create --region RegionOne identity public http://${CONTROLLER_NAME}:5000/v2.0
openstack endpoint create --region RegionOne identity internal http://${CONTROLLER_NAME}:5000/v2.0
openstack endpoint create --region RegionOne identity admin http://${CONTROLLER_NAME}:35357/v2.0


echo "OPENSTACK IDENTITY CREATE ADMIN PROJECT"
openstack project create --domain default --description "Admin Project" admin

echo "OPENSTACK IDENTITY CREATE SERVICE PROJECT"
openstack project create --domain default --description "Service Project" service

echo "OPENSTACK IDENTITY CREATE DEMO PROJECT"
openstack project create --domain default --description "Demo Project" demo

echo "OPENSTACK IDENTITY CREATE USERS AND ROLES FOR PROJECTS"
# ROLES
openstack role create admin
openstack role create user

#USERS
openstack user create --domain default --password ${DEFAULT_PASSWORD} admin
openstack role add --project admin --user admin admin

openstack user create --domain default --password ${DEFAULT_PASSWORD} demo
openstack role add --project demo --user demo user


#Clean temp configs
#From /etc/keystone/keystone-paste.ini remove admin_token_auth from the [pipeline:public_api],
#[pipeline:admin_api], and [pipeline:api_v3] sections.
unset OS_TOKEN OS_URL

mv /tmp/admin-openrc.sh ${HOME}/admin-openrc.sh && chmod 700 ${HOME}/admin-openrc.sh
sed -i "s/^ServerName.*$/ServerName ${CONTROLLER_NAME}/" ${HOME}/admin-openrc.sh
sed -i "s/ADMIN_PASS/${DEFAULT_PASSWORD}/" ${HOME}/admin-openrc.sh
sed -i "s/CONTROLLER_NAME/${CONTROLLER_NAME}/" ${HOME}/admin-openrc.sh

mv /tmp/demo-openrc.sh ${HOME}/demo-openrc.sh && chmod 700 ${HOME}/demo-openrc.sh
sed -i "s/DEMO_PASS/${DEFAULT_PASSWORD}/" ${HOME}/demo-openrc.sh
sed -i "s/CONTROLLER_NAME/${CONTROLLER_NAME}/" ${HOME}/demo-openrc.sh




# -------------------- GLANCE ------------------ #

echo "OPENSTACK GLANCE"
${MYSQLCMD} "DROP DATABASE IF EXISTS glance;"
${MYSQLCMD} "CREATE DATABASE glance;"
#${MYSQLCMD} "DROP USER IF EXISTS glance;"
${MYSQLCMD} "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '${DEFAULT_PASSWORD}';"
${MYSQLCMD} "GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '${DEFAULT_PASSWORD}';"

echo "OPENSTACK GLANCE SERVICE"
openstack service create --name glance --description "OpenStack Image service" image

echo "OPENSTACK GLANCE CREATE USERS"
openstack user create --domain default --password ${DEFAULT_PASSWORD} glance
openstack role add --project service --user glance admin

echo "OPENSTACK GLANCE CREATE ENDPOINTS"
openstack endpoint create --region RegionOne image public http://${CONTROLLER_NAME}:9292
openstack endpoint create --region RegionOne image internal http://${CONTROLLER_NAME}:9292
openstack endpoint create --region RegionOne image admin http://${CONTROLLER_NAME}:9292

echo "OPENSTACK GLANCE PACKAGES AND CONFIG"
apt-get install -y glance python-glanceclient

#BACKUP original  /etc/glance/glance-api.conf and /etc/glance/glance-registry.conf files
cp -p   /etc/glance/glance-api.conf   /etc/glance/glance-api.conf.original
cp -p /etc/glance/glance-registry.conf /etc/glance/glance-registry.conf.original


#STORAGE for glance images should be defined in yml ... but not yet :|
cat > /etc/glance/glance-api.conf <<EOF
[DEFAULT]
notification_driver = noop

[database]
connection = mysql+pymysql://glance:GLANCE_DBPASS@${CONTROLLER_NAME}/glance

[keystone_authtoken]
auth_uri = http://${CONTROLLER_NAME}:5000
auth_url = http://${CONTROLLER_NAME}:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = glance
password = ${DEFAULT_PASSWORD}

[paste_deploy]
flavor = keystone

[glance_store]
default_store = file
filesystem_store_datadir = /var/lib/glance/images/

EOF

cat > /etc/glance/glance-registry.conf <<EOF
[DEFAULT]
notification_driver = noop

[database]
connection = mysql+pymysql://glance:GLANCE_DBPASS@${CONTROLLER_NAME}/glance

[keystone_authtoken]
auth_uri = http://${CONTROLLER_NAME}:5000
auth_url = http://${CONTROLLER_NAME}:35357
auth_plugin = password
project_domain_id = default
user_domain_id = default
project_name = service
username = glance
password = ${DEFAULT_PASSWORD}

[paste_deploy]
flavor = keystone

EOF

#Populate database
su -s /bin/sh -c "glance-manage db_sync" glance

service glance-registry restart
service glance-api restart

rm -f /var/lib/glance/glance.sqlite

# Force to use API version 2
echo "export OS_IMAGE_API_VERSION=2" | tee -a admin-openrc.sh demo-openrc.sh

# Download cirros image for testing :)
CIRROS_VERSION="$(wget http://download.cirros-cloud.net/version/released -qO -)"
if [ ! -n "${CIRROS_VERSION}"]
then
  echo "WARNING: Could not download a valid cirros version ... "
  echo "WRNING: Image testing could not be executed ..."
else
  wget http://download.cirros-cloud.net/${CIRROS_VERSION}/cirros-${CIRROS_VERSION}-x86_64-disk.img -qO /tmp/cirros.img
  source ${HOME}/admin-openrc.sh && glance image-create --name "cirros" \
    --file /tmp/cirros.img \
    --disk-format qcow2 --container-format bare \
    --visibility public

fi
