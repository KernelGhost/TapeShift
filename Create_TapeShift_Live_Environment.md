# Create a Bootable TapeShift Live Environment ISO
These instructions detail how to build a Debian-based live ISO pre-configured with TapeShift. This portable system allows for video capture without a permanent Linux installation, ensuring a reproducible environment that does not interfere with existing installed operating systems. Since booting from this ISO loads the system entirely into RAM, the boot USB can be removed after startup to free ports for capture hardware or external storage.

> [!NOTE]
> Although these instructions utilise Podman, a Debian WSL2 instance on Windows should also work.

1. Create a Debian container.
    ```bash
    sudo apt install podman
    mkdir -p ${HOME}/tapeshift-live
    podman run -it \
      --replace \
      --name tapeshift-live-builder \
      --privileged \
      --security-opt label=disable \
      -v ${HOME}/tapeshift-live:/shared_folder \
      debian:trixie bash
    ```

2. Install the required packages.
    ```bash
    apt update && apt install -y live-build debootstrap squashfs-tools wget
    ```

3. Create the build directory.
    ```bash
    mkdir ${HOME}/build && cd ${HOME}/build
    ```

4. Configure the live build.
    ```bash
    lb config \
      --distribution trixie \
      --binary-images iso-hybrid \
      --debian-installer none \
      --bootappend-live "boot=live components toram username=tapeshift live-config.user-password=false" \
      --iso-publisher "TapeShift" \
      --iso-application "TapeShift Live Environment" \
      --iso-volume "TapeShift Live Environment" \
      --architectures amd64 \
      --linux-packages "linux-image"
    ```

5. Specify the required packages.
    ```bash
    mkdir -p config/package-lists
    cat > config/package-lists/tapeshift.list.chroot <<'EOF'
    live-boot
    live-config
    live-config-systemd
    xfce4
    xfce4-terminal
    lightdm
    lightdm-gtk-greeter
    network-manager
    network-manager-gnome
    vlc
    ffmpeg
    v4l-utils
    alsa-utils
    pulseaudio
    pavucontrol
    usbutils
    udisks2
    gvfs
    dconf-cli
    dconf-service
    gsettings-desktop-schemas
    dbus-x11
    x11-xserver-utils
    EOF
    ```

6. Package TapeShift.
    ```bash
    wget -P /tmp https://raw.githubusercontent.com/KernelGhost/TapeShift/refs/heads/main/TapeShift.sh
    mkdir -p config/includes.chroot/usr/local/bin
    mv /tmp/TapeShift.sh config/includes.chroot/usr/local/bin/tapeshift
    chmod +x config/includes.chroot/usr/local/bin/tapeshift
    ```

7. Create a launcher for TapeShift.
    ```bash
    mkdir -p config/includes.chroot/usr/share/applications
    cat > config/includes.chroot/usr/share/applications/tapeshift.desktop <<'EOF'
    [Desktop Entry]
    Name=TapeShift
    Exec=xfce4-terminal --hold --command tapeshift
    Icon=utilities-terminal
    Type=Application
    Categories=Utility;
    EOF
    ```

8. Add a TapeShift launcher to the Desktop.
    ```bash
    mkdir -p config/includes.chroot/etc/skel/Desktop
    cp config/includes.chroot/usr/share/applications/tapeshift.desktop config/includes.chroot/etc/skel/Desktop/
    chmod +x config/includes.chroot/etc/skel/Desktop/tapeshift.desktop
    ```

9. Enable automatic login.
    ```bash
    mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
    cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/01-autologin.conf <<'EOF'
    [Seat:*]
    autologin-user=tapeshift
    autologin-user-timeout=0
    EOF
    ```

10. Disable all sleep modes as well as ignore lid and suspend keys.
    ```bash
    mkdir -p config/includes.chroot/etc/systemd/sleep.conf.d
    cat > config/includes.chroot/etc/systemd/sleep.conf.d/10-tapeshift-no-sleep.conf <<'EOF'
    [Sleep]
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
    EOF
    ```

    ```bash
    mkdir -p config/includes.chroot/etc/systemd/logind.conf.d
    cat > config/includes.chroot/etc/systemd/logind.conf.d/10-tapeshift-ignore-lid.conf <<'EOF'
    [Login]
    HandleSuspendKey=ignore
    HandleHibernateKey=ignore
    HandleLidSwitch=ignore
    HandleLidSwitchExternalPower=ignore
    HandleLidSwitchDocked=ignore
    EOF
    ```

11. Configure XFCE session behaviour on login.
    ```bash
    cat > config/includes.chroot/usr/local/bin/tapeshift-login <<'EOF'
    #!/bin/bash

    # Wait for Session DBus
    until gsettings list-schemas >/dev/null 2>&1; do
        sleep 1
    done
    
    # Disable XFCE Screensaver
    xfconf-query -c xfce4-screensaver -p /saver/enabled -s false 2>/dev/null

    # Disable XFCE Power Manager Display Blanking
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 2>/dev/null
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false 2>/dev/null

    # Disable AC Power Management (MATE)
    #gsettings set org.mate.session idle-delay 0                      # Session Never Idle
    #gsettings set org.mate.screensaver lock-enabled false            # Disable Lock Screen
    #gsettings set org.mate.screensaver idle-activation-enabled false # Disable Screensaver
    #gsettings set org.mate.power-manager sleep-display-ac 0          # Disable Monitor Sleep
    #gsettings set org.mate.power-manager sleep-computer-ac 0         # Disable System Sleep
    #gsettings set org.mate.power-manager button-lid-ac 'nothing'     # Disable Lid Close

    # Disable X11 Blanking / DPMS (Final Safeguard)
    xset s off     # Disable Screensaver
    xset -dpms     # Disable DPMS (Energy Star) Features
    xset s noblank # Disable Screen Blanking
    EOF
    chmod +x config/includes.chroot/usr/local/bin/tapeshift-login

    # Autostart the first-login setup every session
    mkdir -p config/includes.chroot/etc/xdg/autostart
    cat > config/includes.chroot/etc/xdg/autostart/tapeshift-login.desktop <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=TapeShift Session Setup
    Exec=/usr/local/bin/tapeshift-login
    X-GNOME-Autostart-enabled=true
    NoDisplay=false
    EOF
    ```

12. Build the bootable ISO.
    ```bash
    lb build --debug
    ```
> [!IMPORTANT]
> During the build, you may encounter warnings or errors stating 'Failed to copy xattr: Operation not supported'. These are non-critical and can be safely ignored.

13. Export the ISO to the host system.
    ```bash
    cp live-image-amd64.hybrid.iso /shared_folder/TapeShift_Live_amd64.iso
    ```

14. (Optional) Delete the Debian image and container.
    ```bash
    podman rm tapeshift-live-builder
    podman rmi debian:trixie
    ```
