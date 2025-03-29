# install-appimage

I just AI'd this script to "install" Appimages without the use of FUSE.
# Description: Installs an AppImage by extracting it and creating a .desktop file.
# Features:
   - No FUSE required.
   - Extracts to ~/Applications/<AppName>.
   - Creates .desktop file in ~/.local/share/applications/.
   - Copies icon to ~/.local/share/icons/.
   - Attempts to patch common AppRun APPDIR detection bugs.
   - Correctly generates Exec= line, handling existing field codes.
