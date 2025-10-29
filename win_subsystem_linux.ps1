# ============================================================
#  Debian 13 Minimal on Windows Subsystem for Linux (WSL2)
#  Reference: https://wiki.debian.org/InstallingDebianOn/Microsoft/Windows/SubsystemForLinux
# ============================================================


# --- Enable Windows Features --------------------------------
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

# Set WSL2 as the default backend
wsl --set-default-version 2

# Define custom installation directory (e.g. on drive D:)
wsl --set-default-dir D:\WSL


# --- Install Kernel / Distribution --------------------------
# Option 1: Install WSL core only (no distribution)
wsl --install --no-distribution

# Option 2: Install a predefined distribution (example: Debian)
wsl --install -d Debian


# --- Set Root as Default User -------------------------------
wsl --manage Debian --set-default-user root


# --- Update Kernel & WSL Core -------------------------------
# If already installed, update to the latest kernel and subsystem
wsl --update


# --- Post-Install Configuration -----------------------------
# Inside Debian, set a root password
sudo passwd root
