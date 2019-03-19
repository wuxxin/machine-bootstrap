#!/bin/bash

# called by dracut
check() {
    require_binaries sshd || return 1
    # 0 enables by default, 255 only on request
    return 255
}

# called by dracut
depends() {
    echo systemd-networkd
}

# called by dracut
install() {
    local ssh_host_key authorized_keys
    ssh_host_key=/etc/ssh/initrd_ssh_host_ed25519_key
    if test ! -e $ssh_host_key; then
        echo "Warning: no dracut host key initrd_ssh_host_ed25519_key found, creating new one"
        ssh-keygen -q -t ed25519 -N '' -f "/etc/ssh/initrd_ssh_host_ed25519_key"
    fi
    inst_simple "${ssh_host_key}.pub" /etc/ssh/ssh_host_ed25519_key.pub
    /usr/bin/install -m 600 "$ssh_host_key" "$initdir/etc/ssh/ssh_host_ed25519_key"

    authorized_keys=/root/.ssh/authorized_keys
    mkdir -p -m 700 "$initdir/etc/ssh/root"
    chmod 700 "$initdir/etc/ssh/root"
    /usr/bin/install -m 600 "$authorized_keys" \
            "$initdir/etc/ssh/root/authorized_keys"

    inst_simple /usr/sbin/sshd 
    inst_simple /etc/default/sshd
    
    inst_simple "${moddir}/initramfs-sshd.service" "$systemdsystemunitdir/initramfs-sshd.service"
    inst_simple "${moddir}/sshd_config" /etc/ssh/sshd_config

    grep '^sshd:' /etc/passwd >> "$initdir/etc/passwd"
    grep '^sshd:' /etc/group  >> "$initdir/etc/group"

    systemctl --root "$initdir" enable initramfs-sshd

    if which netplan > /dev/null; then
        netplan generate
    fi
    mkdir -p "$initdir/etc/systemd/network"
    for i in $(find /run/systemd/network -name "*.network"); do 
        /usr/bin/install -m 644 "$i" "$initdir/etc/systemd/network/$(basename $i)"
    done
    
    inst_hook pre-pivot 20 "$moddir/stop-initramfs-sshd.sh"
    
    # fix plymouth config, should be in plymouth
    inst_simple /etc/plymouth/plymouthd.conf

    return 0
}

