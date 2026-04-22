#!/bin/sh
# 首次启动执行脚本 - 全放行防火墙 + 智能USB网卡优先
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "=== 99-custom.sh started at $(date) ===" >>$LOGFILE

# ---------- 1. 防火墙：彻底放行所有区域输入（确保WAN/LAN均可管理） ----------
echo "Configuring firewall: ACCEPT all zones input" >>$LOGFILE
uci -q batch <<EOF
set firewall.@zone[0].input='ACCEPT'
set firewall.@zone[1].input='ACCEPT'
commit firewall
EOF

# ---------- 2. 基础设置：主机名、时区、语言、DHCP域名劫持 ----------
uci set system.@system[0].hostname='iStoreOS'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'

uci set luci.main.lang='zh_cn'
uci commit system
uci commit luci

uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"
uci commit dhcp

# ---------- 3. 智能网络配置：USB网卡优先，自动屏蔽无载波内置口 ----------
echo "Starting intelligent network config..." >>$LOGFILE

# 获取所有物理以太网接口
get_physical_eth_ifs() {
    local if_list=""
    for iface in /sys/class/net/*; do
        iface_name=$(basename "$iface")
        [ "$iface_name" = "lo" ] && continue
        # 必须有device目录且不是无线接口
        if [ -e "$iface/device" ] && ! [ -d "$iface/wireless" ]; then
            if echo "$iface_name" | grep -Eq '^eth|^en'; then
                if_list="$if_list $iface_name"
            fi
        fi
    done
    echo "$if_list" | xargs
}

# 判断是否为USB网卡
is_usb_eth() {
    local iface="$1"
    if [ -L "/sys/class/net/$iface/device" ] && readlink "/sys/class/net/$iface/device" | grep -q "usb"; then
        return 0
    fi
    if [ -f "/sys/class/net/$iface/device/uevent" ]; then
        if grep -qE "DRIVER=(r8152|ax88179|asix|smsc95xx|rtl8150|dm9601|mcs7830|sr9700)" "/sys/class/net/$iface/device/uevent"; then
            return 0
        fi
    fi
    return 1
}

# 判断接口是否有载波（用于忽略空口）
has_carrier() {
    local iface="$1"
    local carrier_file="/sys/class/net/$iface/carrier"
    if [ -f "$carrier_file" ] && [ "$(cat "$carrier_file")" = "1" ]; then
        return 0
    fi
    return 1
}

all_ifs=$(get_physical_eth_ifs)
echo "All physical Ethernet interfaces: $all_ifs" >>$LOGFILE

usb_ifs=""
builtin_ifs=""
for iface in $all_ifs; do
    if is_usb_eth "$iface"; then
        usb_ifs="$usb_ifs $iface"
        echo "$iface is USB Ethernet" >>$LOGFILE
    else
        # 内置接口只保留有载波的
        if has_carrier "$iface"; then
            builtin_ifs="$builtin_ifs $iface"
            echo "$iface is built-in with carrier" >>$LOGFILE
        else
            echo "$iface is built-in but no carrier, ignoring" >>$LOGFILE
        fi
    fi
done

# 清除可能存在的旧网络配置
while uci -q delete network.@device[0]; do :; done
uci -q delete network.wan
uci -q delete network.wan6

# 优先使用USB网卡
if [ -n "$usb_ifs" ]; then
    echo "USB Ethernet detected, using them as primary." >>$LOGFILE
    # 第一个USB网卡作为基础
    set -- $usb_ifs
    lan_if="$1"
    shift
    extra_usb="$@"

    # 创建LAN接口
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='192.168.100.1'
    uci set network.lan.netmask='255.255.255.0'

    # 如果只有一个USB网卡，直接绑定
    if [ -z "$extra_usb" ]; then
        uci set network.lan.device="$lan_if"
    else
        # 多个USB网卡全部加入br-lan
        uci set network.lan.device='br-lan'
        uci set network.device_br_lan=bridge
        uci set network.device_br_lan.name='br-lan'
        for port in $lan_if $extra_usb; do
            uci add_list network.device_br_lan.ports="$port"
        done
        echo "Added $lan_if and $extra_usb to br-lan" >>$LOGFILE
    fi
    uci commit network
    echo "Network config: LAN (USB) = 192.168.100.1" >>$LOGFILE

else
    # 无USB网卡，回退内置网口逻辑
    echo "No USB Ethernet found, fallback to built-in interfaces." >>$LOGFILE
    if [ -z "$builtin_ifs" ]; then
        echo "ERROR: No usable Ethernet interface found! Network may not work." >>$LOGFILE
    else
        count=$(echo "$builtin_ifs" | wc -w)
        echo "Available built-in interfaces: $builtin_ifs (count=$count)" >>$LOGFILE
        if [ "$count" -eq 1 ]; then
            # 单网口：DHCP模式（防火墙已全开，可直接访问）
            uci set network.lan=interface
            uci set network.lan.device="$(echo $builtin_ifs)"
            uci set network.lan.proto='dhcp'
            uci commit network
            echo "Single built-in port: set LAN to DHCP" >>$LOGFILE
        else
            # 多网口：第一个为WAN（DHCP），其余加入LAN桥
            wan_if=$(echo "$builtin_ifs" | awk '{print $1}')
            lan_ports=$(echo "$builtin_ifs" | cut -d' ' -f2-)

            uci set network.wan=interface
            uci set network.wan.device="$wan_if"
            uci set network.wan.proto='dhcp'
            uci set network.wan6=interface
            uci set network.wan6.device="$wan_if"
            uci set network.wan6.proto='dhcpv6'

            uci set network.lan=interface
            uci set network.lan.proto='static'
            uci set network.lan.ipaddr='192.168.100.1'
            uci set network.lan.netmask='255.255.255.0'
            uci set network.lan.device='br-lan'

            uci set network.device_br_lan=bridge
            uci set network.device_br_lan.name='br-lan'
            for port in $lan_ports; do
                uci add_list network.device_br_lan.ports="$port"
            done
            uci commit network
            echo "Multi built-in ports: WAN=$wan_if, LAN=$lan_ports" >>$LOGFILE
        fi
    fi
fi

# ---------- 4. 允许所有接口访问TTYD和SSH ----------
uci -q delete ttyd.@ttyd[0].interface
uci set dropbear.@dropbear[0].Interface=''
uci commit dropbear

# ---------- 5. 还原banner并清理临时文件 ----------
if [ -d /etc/banner1 ]; then
    cp /etc/banner1/banner /etc/
    rm -r /etc/banner1
fi

# ---------- 6. 写入版本信息（会被工作流sed替换） ----------
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='iStoreOS 版本号'/" /etc/openwrt_release 2>/dev/null

echo "=== 99-custom.sh finished at $(date) ===" >>$LOGFILE
exit 0
