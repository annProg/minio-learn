#!/bin/bash
mv /etc/yum.repos.d/* /tmp
curl -s http://mirrors.aliyun.com/repo/Centos-7.repo -o /etc/yum.repos.d/CentOS-Base.repo

function restoreRepo() {
	[ -f /tmp/$1.repo ] && mv /tmp/$1.repo /etc/yum.repos.d
}

function Install() {
	rpm -qa |grep -w "$1" || yum install -y $1
}

# 恢复被移走的repo
restoreRepo puppet6
restoreRepo epel

# 安装 常用/必要 软件
Install wget
Install vim
# chattr
Install e2fsprogs
# 确保你的包管理器安装了优先级/首选项包且已启用。在 CentOS 上你也许得安装 EPEL ，在 RHEL 上你也许得启用可选软件库。
Install epel-release

# puppet
#rpm -Uvh https://yum.puppet.com/puppet6-release-el-7.noarch.rpm
#yum Install -y puppetserver --enablerepo=puppet6

# 时区
rm -rf /etc/localtime
ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 主机名解析
value=$( grep -ic "entry" /etc/hosts )
if [ $value -eq 0 ]
then
echo "
################ cookbook host entry ############

192.168.1.111 node1
192.168.1.112 node2
192.168.1.113 node3
192.168.1.114 node4
192.168.1.115 node5

######################################################
" >> /etc/hosts
fi

# Note 主机名应该解析为网络 IP 地址，而非回环接口 IP 地址（即主机名应该解析成非 127.0.0.1 的IP地址）
sed -i '/^127.0.0.1.*node/d' /etc/hosts

# ntp. 分布式 minio 需要时间同步
Install ntpdate
Install ntp

# 换用国内ntp，解决 ceph mon clock skew detected 问题，国外ntp延时超过0.05s
sed -i -r '/^server /d' /etc/ntp.conf
cat >> /etc/ntp.conf <<EOF
server ntp.ntsc.ac.cn iburst prefer
server ntp.aliyun.com iburst
server ntp2.aliyun.com iburst
server ntp3.aliyun.com iburst
server ntp4.aliyun.com iburst
EOF

systemctl enable ntpd
systemctl enable ntpdate
systemctl stop ntpd
systemctl stop ntpdate
ntpdate ntp.ntsc.ac.cn > /dev/null 2> /dev/null
systemctl start ntpdate
systemctl start ntpd


# 格式化磁盘
declare -A DEVICE
DEVICE=(
	[sdb]=data1
	[sdc]=data2
	[sdd]=data3
	[sde]=data4
	[sdf]=data5
	[sdg]=data6
)

for sd in ${!DEVICE[@]};do
	if [ ! -b /dev/${sd}1 ];then
		echo -e "\033[31m$sd ${DEVICE[$sd]}[0m"
		echo -e "n\np\n\n\n\nw" |fdisk /dev/$sd
		mkfs.xfs /dev/${sd}1
	fi

	directory=/${DEVICE[$sd]}
	[ ! -d $directory ] && mkdir $directory

	# 挂载点未挂载时不允许写入
	mountpoint -q $directory
	if [ $? -eq 0 ];then
		echo "$directory mounted"
	else
		chattr +i $directory
		mount -t xfs /dev/${sd}1 $directory
	fi

	# fstab
	grep "^/dev/${sd}1" || echo "/dev/${sd}1 $directory xfs defaults 0 0" >> /etc/fstab
done

# 允许密码登录
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
systemctl restart sshd

# 在 CentOS 和 RHEL 上， SELinux 默认为 Enforcing 开启状态。为简化安装，我们建议把 SELinux 设置为 Permissive 或者完全禁用，也就是在加固系统配置前先确保集群的安装、配置没问题。用下列命令把 SELinux 设置为 Permissive 
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

# 互相ssh
su -c 'cat /dev/zero |ssh-keygen -q -N ""' vagrant
Install sshpass
Install nmap-ncat
for node in `seq 1 3`;do
	nc -z node${node} 22 && \
	su -c "sshpass -p vagrant ssh-copy-id vagrant@node${node} -o StrictHostKeyChecking=no" vagrant
done

# root 互相ssh
cat /dev/zero |ssh-keygen -q -N ""
for node in `seq 1 3`;do
	nc -z node${node} 22 && \
	sshpass -p vagrant ssh-copy-id node${node} -o StrictHostKeyChecking=no
done

# 下载并启动 3 租户 minio
[ ! -f /usr/bin/minio ] && curl -s -L https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/bin/minio && chmod +x /usr/bin/minio

function tenant() {
	cat > /usr/lib/systemd/system/$1.service <<EOF
[Unit]
Description=Minio
Documentation=https://docs.minio.io
Wants=network-online.target
After=network-online.target
AssertFileIsExecutable=/usr/bin/minio

[Service]
WorkingDirectory=/usr/local

User=minio-user
Group=minio-user

PermissionsStartOnly=true

EnvironmentFile=-/etc/default/$1
ExecStartPre=/bin/bash -c "[ -n \"${MINIO_VOLUMES}\" ] || echo \"Variable MINIO_VOLUMES not set in /etc/defaults/minio\""

ExecStart=/usr/bin/minio server $MINIO_OPTS $MINIO_VOLUMES

# Let systemd restart this service only if it has ended with the clean exit code or signal.
Restart=on-success

StandardOutput=journal
StandardError=inherit

# Specifies the maximum file descriptor number that can be opened by this process
LimitNOFILE=65536

# Disable timeout logic and wait until process is stopped
TimeoutStopSec=0

# SIGTERM signal is used to stop Minio
KillSignal=SIGTERM

SendSIGKILL=no

SuccessExitStatus=0

[Install]
WantedBy=multi-user.target
EOF

	systemctl enable $1
	systemctl start $1
}

cat > /etc/default/minio1 <<EOF
MINIO_ACCESS_KEY=minio1
MINIO_SECRET_KEY=passminio1
MINIO_OPTIONS=--address :9001
MINIO_VOLUMES=http://192.168.1.111/data1 http://192.168.1.112/data1 http://192.168.1.113/data1 http://192.168.1.111/data2 http://192.168.1.112/data2 http://192.168.1.113/data2
EOF

tenant minio1