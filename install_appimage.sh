#!/bin/bash

# Title: install_appimage.sh
# Description: Installs an AppImage by extracting it and creating a .desktop file.
# Features:
#   - No FUSE required.
#   - Extracts to ~/Applications/<AppName>.
#   - Creates .desktop file in ~/.local/share/applications/.
#   - Copies icon to ~/.local/share/icons/.
#   - Attempts to patch common AppRun APPDIR detection bugs.
#   - Correctly generates Exec= line, handling existing field codes.

# Exit immediately if a command exits with a non-zero status.
set -ex

# --- Configuration ---
APPS_DIR="${HOME}/Applications"
DESKTOP_DIR="${HOME}/.local/share/applications"
ICON_BASE_DIR="${HOME}/.local/share/icons/hicolor"

# --- Input Validation ---
if [ -z "$1" ]; then
  echo "Usage: $(basename "$0") <path/to/YourApp.AppImage>"
  exit 1
fi

APPIMAGE_PATH=$(realpath "$1")

if [ ! -f "$APPIMAGE_PATH" ]; then
  echo "Error: File not found: $APPIMAGE_PATH"
  exit 1
fi

if [ ! -x "$APPIMAGE_PATH" ]; then
   echo "Warning: AppImage might not be executable ('chmod +x \"$APPIMAGE_PATH\"')."
   echo "         Extraction might fail. Attempting anyway..."
fi

# --- Derive Names and Paths ---
APPIMAGE_FILENAME=$(basename "$APPIMAGE_PATH")
APP_NAME=$(echo "$APPIMAGE_FILENAME" | sed -e 's/\.AppImage$//i' -e 's/-x86_64$//' -e 's/-amd64$//' -e 's/-i[3-6]86$//' -e 's/-armhf$//' -e 's/-aarch64$//' -e 's/_//g')
INSTALL_DIR="${APPS_DIR}/${APP_NAME}"
DESKTOP_FILE_PATH="${DESKTOP_DIR}/${APP_NAME}.desktop"

echo "--- Installing $APP_NAME ---"
echo "Source AppImage: $APPIMAGE_PATH"
echo "Target Directory: $INSTALL_DIR"

# --- Create Directories ---
mkdir -p "$INSTALL_DIR"
mkdir -p "$DESKTOP_DIR"

# --- Extract AppImage ---
echo "Extracting AppImage (this might take a moment)..."
ORIG_DIR=$(pwd)
cd "$INSTALL_DIR"
if ! "$APPIMAGE_PATH" --appimage-extract > /dev/null; then
     echo "Error: Failed to extract AppImage." >&2
     echo "       Check if it's a valid AppImage and maybe try 'chmod +x' on it." >&2
     cd "$ORIG_DIR"
     exit 1
fi
EXTRACTED_DIR="${INSTALL_DIR}/squashfs-root"
cd "$ORIG_DIR"

if [ ! -d "$EXTRACTED_DIR" ]; then
    echo "Error: Extraction failed. 'squashfs-root' directory not found in $INSTALL_DIR." >&2
    exit 1
fi
echo "Extraction complete: $EXTRACTED_DIR"


# --- BEGIN AppRun Patching ---
# Specific patch for AppRun scripts with faulty APPDIR detection loop
APPRUN_TARGET="${EXTRACTED_DIR}/AppRun"

if [ -f "$APPRUN_TARGET" ]; then
    echo "Checking AppRun script for known problematic APPDIR logic..."

    # Define patterns for the grep check (less escaping needed for '/')
    GREP_WHILE_PATTERN='^[[:space:]]*while \[\[ "\$path" != "" && ! -e "\$path/\$1" \]\]; do'
    GREP_INSIDE_LOOP_PATTERN='^[[:space:]]*path=\$\{path%/\*\}' # Match literal '*'
    GREP_DONE_PATTERN='^[[:space:]]*done'

    # Check if the problematic loop actually exists using grep patterns
    if grep -q -E "$GREP_WHILE_PATTERN" "$APPRUN_TARGET" && \
       grep -q -E "$GREP_INSIDE_LOOP_PATTERN" "$APPRUN_TARGET" && \
       grep -q -E "$GREP_DONE_PATTERN" "$APPRUN_TARGET"; then

        echo "Problematic APPDIR detection loop found in $APPRUN_TARGET. Attempting patch..."

        # Create a backup first
        cp "$APPRUN_TARGET" "${APPRUN_TARGET}.bak"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create backup of AppRun. Aborting patch." >&2
            exit 1
        else
            # Define patterns for sed (needs '/' escaped in address pattern)
            SED_WHILE_PATTERN='^[[:space:]]*while \[\[ "\$path" != "" && ! -e "\$path\/\$1" \]\]; do'
            SED_INSIDE_LOOP_PATTERN='^[[:space:]]*path=\${path%\/\*}' # Match literal '*'
            SED_DONE_PATTERN='^[[:space:]]*done'

            # Use sed to delete the specific lines related to the while loop in-place
            sed -i \
                -e "/${SED_WHILE_PATTERN}/d" \
                -e "/${SED_INSIDE_LOOP_PATTERN}/d" \
                -e "/${SED_DONE_PATTERN}/d" \
                "$APPRUN_TARGET"

            # Check if sed command succeeded (exit code 0)
            if [ $? -eq 0 ]; then
                echo "AppRun patching applied successfully."
                rm "${APPRUN_TARGET}.bak" # Remove backup on success
            else
                echo "Warning: AppRun patching failed. Restoring backup." >&2
                mv "${APPRUN_TARGET}.bak" "$APPRUN_TARGET" || echo "Error: Failed restoring backup!" >&2
                echo "Proceeding with potentially unpatched AppRun."
            fi
        fi
    else
        echo "Known problematic APPDIR loop not found. Skipping AppRun patch."
    fi
else
    echo "Warning: AppRun script not found at $APPRUN_TARGET. Cannot check for/apply patch."
fi
# --- END AppRun Patching ---


# --- Find Internal Desktop File ---
INTERNAL_DESKTOP_FILE=$(find "$EXTRACTED_DIR" -maxdepth 1 -type f -name '*.desktop' -print -quit)

# --- Initialize Metadata Variables ---
EXEC_REL_PATH=""
ICON_NAME=""
APP_REAL_NAME=""
COMMENT=""
CATEGORIES=""
TERMINAL=""

if [ -z "$INTERNAL_DESKTOP_FILE" ]; then
    echo "Warning: Could not find internal .desktop file in $EXTRACTED_DIR."
    # --- Fallback Logic (No .desktop file) ---
    echo "         Attempting to use 'AppRun' as fallback executable."
    FALLBACK_EXEC="AppRun"
    if [ -f "${EXTRACTED_DIR}/${FALLBACK_EXEC}" ]; then
       EXEC_REL_PATH="$FALLBACK_EXEC"
       echo "         Using fallback Exec=$EXEC_REL_PATH"
       APP_REAL_NAME="$APP_NAME"
       COMMENT="Installed AppImage"
       CATEGORIES="Utility;"
       TERMINAL="false"
       ICON_NAME=""
    else
       echo "Error: Cannot determine executable. No .desktop file found and fallback '${FALLBACK_EXEC}' not found in $EXTRACTED_DIR." >&2
       exit 1
    fi
    # --- End Fallback Logic ---
else
    echo "Found internal desktop file: $INTERNAL_DESKTOP_FILE"
    # --- Parse Internal Desktop File ---
    EXEC_REL_PATH=$(grep -E '^Exec=' "$INTERNAL_DESKTOP_FILE" | head -n 1 | sed 's/^Exec=//')
    ICON_NAME=$(grep -E '^Icon=' "$INTERNAL_DESKTOP_FILE" | head -n 1 | sed 's/^Icon=//')
    APP_REAL_NAME=$(grep -E '^Name=' "$INTERNAL_DESKTOP_FILE" | head -n 1 | sed 's/^Name=//')
    COMMENT=$(grep -E '^Comment=' "$INTERNAL_DESKTOP_FILE" | head -n 1 | sed 's/^Comment=//')
    CATEGORIES=$(grep -E '^Categories=' "$INTERNAL_DESKTOP_FILE" | head -n 1 | sed 's/^Categories=//')
    TERMINAL=$(grep -E '^Terminal=' "$INTERNAL_DESKTOP_FILE" | head -n 1 | sed 's/^Terminal=//' | tr '[:upper:]' '[:lower:]') # Normalize

    # --- Fallback/Default Handling (Parsing Done) ---
    if [ -z "$EXEC_REL_PATH" ]; then
        echo "Warning: Could not parse 'Exec=' line from $INTERNAL_DESKTOP_FILE."
        echo "         Attempting to use 'AppRun' as fallback executable."
        FALLBACK_EXEC="AppRun"
        if [ -f "${EXTRACTED_DIR}/${FALLBACK_EXEC}" ]; then
            EXEC_REL_PATH="$FALLBACK_EXEC"
            echo "         Using fallback Exec=$EXEC_REL_PATH"
        else
            echo "Error: Cannot determine executable. No Exec= line found and fallback '${FALLBACK_EXEC}' not found." >&2
            exit 1
        fi
    fi
    if [ -z "$APP_REAL_NAME" ]; then APP_REAL_NAME="$APP_NAME"; fi
    if [ -z "$TERMINAL" ]; then TERMINAL="false"; fi
    if [ -z "$CATEGORIES" ]; then CATEGORIES="Utility;"; fi
    if [ -z "$ICON_NAME" ]; then echo "Warning: Could not parse 'Icon=' line. Proceeding without specific icon."; fi
     # --- End Fallback/Default Handling ---
fi


# --- Generate Final Exec= Command String ---
POTENTIAL_FULL_EXEC_CMD="${EXTRACTED_DIR}/${EXEC_REL_PATH}"
if echo "$EXEC_REL_PATH" | grep -q '%[a-zA-Z]'; then
    FINAL_EXEC_CMD="$POTENTIAL_FULL_EXEC_CMD"
    echo "Internal/Fallback Exec already contains field code. Final Exec= line will be: $FINAL_EXEC_CMD"
else
    FINAL_EXEC_CMD="$POTENTIAL_FULL_EXEC_CMD %U"
    echo "Internal/Fallback Exec lacks field code. Appending %U. Final Exec= line will be: $FINAL_EXEC_CMD"
fi


# --- Check existence and permissions of the *actual executable file* ---
EXEC_FILE_REL_PATH=$(echo "$EXEC_REL_PATH" | cut -d' ' -f1)
FULL_EXEC_FILE_CHECK="${EXTRACTED_DIR}/${EXEC_FILE_REL_PATH}"

echo "Checking actual executable file exists: $FULL_EXEC_FILE_CHECK"
if [ ! -f "$FULL_EXEC_FILE_CHECK" ]; then
   echo "Error: Executable file '$FULL_EXEC_FILE_CHECK' (derived from Exec= line) not found." >&2
   exit 1
elif [ ! -x "$FULL_EXEC_FILE_CHECK" ]; then
   echo "Warning: Executable '$FULL_EXEC_FILE_CHECK' found but lacks execute permissions. Attempting 'chmod +x'..."
   chmod +x "$FULL_EXEC_FILE_CHECK"
   if [ ! -x "$FULL_EXEC_FILE_CHECK" ]; then
     echo "Error: Failed to set execute permission on $FULL_EXEC_FILE_CHECK" >&2
     exit 1
   fi
   echo "Execute permission set."
fi


# --- Find and Install Icon ---
INSTALLED_ICON_NAME="" # Default to empty if no icon found/specified
if [ -n "$ICON_NAME" ]; then
    echo "Searching for icon files matching name: '$ICON_NAME'..."
    # Use find -L to follow symlinks. Search the whole extracted directory.
    # Find regular files (-type f) matching the base icon name with common extensions.
    ICON_PATH=$(find -L "$EXTRACTED_DIR" \
                   -type f \( -name "${ICON_NAME}.svg" -o -name "${ICON_NAME}.png" -o -name "${ICON_NAME}.xpm" -o -name "${ICON_NAME}.ico" \) \
                   -printf "%p\n" | head -n 1 ) # Take the first match

    if [ -z "$ICON_PATH" ]; then
        echo "Warning: Icon file matching '$ICON_NAME' not found within $EXTRACTED_DIR (after following links). Skipping icon installation."
    else
        echo "Found icon file: $ICON_PATH"
        ICON_EXT="${ICON_PATH##*.}"
        DEST_ICON_NAME="$ICON_NAME" # Use name from .desktop file
        ICON_DEST_DIR=""

        if [[ "$ICON_EXT" == "svg" ]]; then
            ICON_DEST_DIR="${ICON_BASE_DIR}/scalable/apps"
        else
            ICON_SIZE=$(echo "$ICON_PATH" | grep -o -E '[0-9]+x[0-9]+')
            if [ -n "$ICON_SIZE" ]; then
                 ICON_DEST_DIR="${ICON_BASE_DIR}/${ICON_SIZE}/apps"
            else
                 ICON_DEST_DIR="${ICON_BASE_DIR}/256x256/apps" # Fallback size
            fi
        fi

        mkdir -p "$ICON_DEST_DIR"
        cp "$ICON_PATH" "${ICON_DEST_DIR}/${DEST_ICON_NAME}.${ICON_EXT}"
        INSTALLED_ICON_NAME="$DEST_ICON_NAME" # Use name without extension in .desktop file
        echo "Installed icon ($INSTALLED_ICON_NAME) to: ${ICON_DEST_DIR}/${DEST_ICON_NAME}.${ICON_EXT}"
    fi
else
    echo "No icon name specified or found in internal .desktop file. Skipping icon installation."
fi
# --- End Find and Install Icon ---


# --- Create .desktop File ---
echo "Creating desktop file: $DESKTOP_FILE_PATH"
cat << EOF > "$DESKTOP_FILE_PATH"
[Desktop Entry]
Version=1.0
Type=Application
Name=$APP_REAL_NAME
Comment=$COMMENT
Exec=$FINAL_EXEC_CMD
Icon=$INSTALLED_ICON_NAME
Terminal=$TERMINAL
Categories=$CATEGORIES
Path=$EXTRACTED_DIR

# Custom fields for tracking (optional)
X-AppImage-Install-Script=true
X-AppImage-Original-Path=$APPIMAGE_PATH
X-AppImage-Install-Dir=$INSTALL_DIR
EOF

chmod +x "$DESKTOP_FILE_PATH"


# --- Update Desktop Database ---
echo "Updating desktop application database..."
if command -v update-desktop-database &> /dev/null; then
    update-desktop-database -q "$DESKTOP_DIR" || echo "Warning: update-desktop-database command failed." >&2
else
    echo "Warning: 'update-desktop-database' command not found. Application might not appear in menu immediately."
fi


# --- Installation Complete ---
echo ""
echo "--- Installation Complete ---"
echo "Application '$APP_REAL_NAME' installed successfully!"
echo ""
echo " > Executable and files are in: $INSTALL_DIR"
echo " > Desktop shortcut created at: $DESKTOP_FILE_PATH"
if [ -n "$INSTALLED_ICON_NAME" ] && [ -n "$ICON_DEST_DIR" ] && [ -n "$ICON_EXT" ]; then
 echo " > Icon installed to: ${ICON_DEST_DIR}/${INSTALLED_ICON_NAME}.${ICON_EXT}"
fi
echo " > You should find '$APP_REAL_NAME' in your application menu (you might need to log out/in or restart shell)."
echo ""
echo " > To Uninstall:"
echo "   1. Remove the application directory: rm -rf \"$INSTALL_DIR\""
echo "   2. Remove the desktop file: rm -f \"$DESKTOP_FILE_PATH\""
# Only add icon removal instructions if an icon was actually installed
if [ -n "$INSTALLED_ICON_NAME" ] && [ -n "$ICON_DEST_DIR" ] && [ -n "$ICON_EXT" ]; then
 echo "   3. Remove the icon: rm -f \"${ICON_DEST_DIR}/${INSTALLED_ICON_NAME}.${ICON_EXT}\" (Verify path first!)"
fi
echo "   4. Update the database: update-desktop-database -q \"$DESKTOP_DIR\""
echo ""

exit 0
