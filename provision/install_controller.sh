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


echo "OPENSTACK KEYSTONE"
${MYSQLCMD} "DROP DATABASE IF EXISTS keystone;"
${MYSQLCMD} "CREATE DATABASE keystone;"
${MYSQLCMD} "DROP USER IF EXISTS keystone;"
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
driver = sql"
EOF

su -s /bin/sh -c "keystone-manage db_sync" keystone

rm -f /var/lib/keystone/keystone.db


#BACKUP original /etc/apache2/apache2.conf file
cp -p /etc/apache2/apache2.conf /etc/apache2/apache2.conf.original
sed -i "s/^ServerName.*$/ServerName ${CONTROLLER_NAME}/" /etc/apache2/apache2.conf

mv /tmp/wsgi-keystone.conf /etc/apache2/sites-available/wsgi-keystone.conf
ln -s /etc/apache2/sites-available/wsgi-keystone.conf /etc/apache2/sites-enabled
service apache2 restart



export OS_TOKEN=${ADMIN_TOKEN}
export OS_URL=http://${CONTROLLER_NAME}:35357/v3
export OS_IDENTITY_API_VERSION=3

echo "OPENSTACK IDENTITY ENDPOINTS"
openstack service create --name keystone --description "OpenStack Identity" identity
openstack endpoint create --region RegionOne identity public http://${CONTROLLER_NAME}:5000/v2.0
openstack endpoint create --region RegionOne identity internal http://${CONTROLLER_NAME}:5000/v2.0
openstack endpoint create --region RegionOne identity admin http://${CONTROLLER_NAME}:35357/v2.0
