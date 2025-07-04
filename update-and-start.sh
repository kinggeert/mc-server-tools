#!/bin/bash
set -e  # Exit immediately if any command fails

# --- Argument Checking ---
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <Xms_in_M> <Xmx_in_M> <repo_path_or_url> <Auto_update_script(Default: 1)>"
    echo "Example (GitHub): $0 1000 8000 https://github.com/SlagterJ/geertenjordy-server.git"
    echo "Example (Local Dev): $0 1000 8000 /home/user/my-local-repo 0"
    exit 1
fi

MEM_MIN="$1"
MEM_MAX="$2"
REPO_SOURCE="$3"
AUTO_UPDATE=1
if [ -n "$4" ]; then
  AUTO_UPDATE="$4"
fi
REPO_DIR="git-repo"
CONFIG_DIR="config"
SCRIPT_NAME="update-and-start.sh"
SERVER_PROPERTIES="server.properties"

# --- Automatically update the script ---
if [ "$AUTO_UPDATE" == "1" ]; then
    OLD_HASH=$(sha256sum update-and-start.sh 2>/dev/null)

    wget -N "https://raw.githubusercontent.com/kinggeert/mc-server-tools/refs/heads/main/update-and-start.sh"

    NEW_HASH=$(sha256sum update-and-start.sh)

    if [ "$OLD_HASH" != "$NEW_HASH" ]; then
        echo "New version downloaded. Running..."
        sh ./update-and-start.sh
        exit 1
    else
        echo "No new version found. Continuing as normal."
    fi
fi

# --- Repository Setup (Handle Local and Remote Repos) ---
if [ -d "$REPO_SOURCE/.git" ]; then
    echo "Using local Git repository: $REPO_SOURCE"
    rm -rf "$REPO_DIR"
    cp -r "$REPO_SOURCE" "$REPO_DIR"
elif [[ "$REPO_SOURCE" =~ ^https?:// ]]; then
    echo "Using remote Git repository: $REPO_SOURCE"
    if [ ! -d "$REPO_DIR" ]; then
        git clone "$REPO_SOURCE" "$REPO_DIR"
    else
        cd "$REPO_DIR" && git pull && cd ..
    fi
else
    echo "Error: '$REPO_SOURCE' is not a valid Git repository path or URL!"
    exit 1
fi

# --- Load secrets ---
if [ -f "./secrets.sh" ]; then
    source ./secrets.sh
    export $(grep -oP '^\w+' secrets.sh)
fi

# --- Download packwiz-installer-bootstrap.jar if missing ---
if [ ! -f packwiz-installer-bootstrap.jar ]; then
    echo "Downloading packwiz-installer-bootstrap.jar..."
    wget -O packwiz-installer-bootstrap.jar "https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar"
fi

# --- Update Mods ---
echo "Running packwiz installer..."
java -jar packwiz-installer-bootstrap.jar -g -s server "$REPO_DIR/pack.toml"

# --- Extract Minecraft Version from pack.toml ---
MINECRAFT_VERSION=$(grep -E '^\s*minecraft\s*=' "$REPO_DIR/pack.toml" | head -n1 | cut -d'"' -f2)
if [ -z "$MINECRAFT_VERSION" ]; then
    echo "Error: Could not extract Minecraft version."
    exit 1
fi
echo "Extracted Minecraft version: $MINECRAFT_VERSION"

# --- Extract modloader from pack.toml
if grep -q "neoforge" "$REPO_DIR/pack.toml"; then
    MODLOADER="neoforge"
    MODLOADER_VERSION=$(grep -E '^\s*neoforge\s*=' "$REPO_DIR/pack.toml" | head -n1 | cut -d'"' -f2)
elif grep -q "forge" "$REPO_DIR/pack.toml"; then
    MODLOADER="forge"
    MODLOADER_VERSION=$(grep -E '^\s*forge\s*=' "$REPO_DIR/pack.toml" | head -n1 | cut -d'"' -f2)
elif grep -q "fabric" "$REPO_DIR/pack.toml"; then
    MODLOADER="fabric"
    MODLOADER_VERSION=$(grep -E '^\s*fabric\s*=' "$REPO_DIR/pack.toml" | head -n1 | cut -d'"' -f2)
elif grep -q "quilt" "$REPO_DIR/pack.toml"; then
    MODLOADER="quilt"
    MODLOADER_VERSION=$(grep -E '^\s*quilt\s*=' "$REPO_DIR/pack.toml" | head -n1 | cut -d'"' -f2)
else
    echo "Error: Could not extract modloader."
fi
echo "Extracted modloader: $MODLOADER $MODLOADER_VERSION"

# --- Update server jar ---
if [ "$MODLOADER" == "fabric" ]; then
    FABRIC_JAR_URL="https://jars.arcadiatech.org/fabric/${MINECRAFT_VERSION}/fabric.jar"
    echo "Checking for updates to server.jar..."
    wget -N -O server.jar "$FABRIC_JAR_URL"
elif [ "$MODLOADER" == "forge" ]; then
    FORGE_INSTALLER_JAR_URL="https://maven.minecraftforge.net/net/minecraftforge/forge/${MINECRAFT_VERSION}-${MODLOADER_VERSION}/forge-${MINECRAFT_VERSION}-${MODLOADER_VERSION}-installer.jar"
    echo "Checking for updates to forge-installer.jar..."
    wget -N -O forge-installer.jar "$FORGE_INSTALLER_JAR_URL"
    echo "Running forge installer..."
    java -jar forge-installer.jar --installServer
#    FORGE_DIR=$(ls -dv libraries/net/minecraftforge/forge/*/ | tail -n1)
#    mv $FORGE_DIR/forge-*-server.jar server.jar
elif [ "$MODLOADER" == "quilt" ]; then
    QUILT_INSTALLER_JAR_URL="https://quiltmc.org/api/v1/download-latest-installer/java-universal"
    echo "Checking for updates to quilt installer jar..."
    wget -N "$QUILT_INSTALLER_JAR_URL"
    java -jar java-universal install server ${MINECRAFT_VERSION} --download-server --install-dir=./
elif [ "$MODLOADER" == "neoforge" ]; then
    NEOFORGE_INSTALLER_JAR_URL="https://maven.neoforged.net/releases/net/neoforged/neoforge/${MODLOADER_VERSION}/neoforge-${MODLOADER_VERSION}-installer.jar"
    echo "Checking for updates to NeoForge installer jar..."
    wget -N -O neoforge-installer.jar "$NEOFORGE_INSTALLER_JAR_URL"
    java -jar neoforge-installer.jar --install-server
else
    echo "Error: No modloader selected."
fi

# --- Replace Environment Variables in Config Files ---
process_file() {
    local file="$1"
    echo "Processing $file"
    tmp_file=$(mktemp) || { echo "Failed to create temporary file"; exit 1; }

    gawk -f - "$file" > "$tmp_file" << 'AWK_EOF'
{
    line = $0
    output = ""
    pos = 1
    # Match only unbraced variables: $ followed immediately by a letter or underscore.
    while (match(substr(line, pos), /\$[A-Za-z_][A-Za-z0-9_]*/)) {
        rstart = pos + RSTART - 1
        # Append text before the match.
        output = output substr(line, pos, RSTART - 1)
        # Extract the variable name (skip the $).
        var = substr(line, rstart+1, RLENGTH-1)
        if (var in ENVIRON) {
            # Replace with the environment variable's value.
            output = output ENVIRON[var]
        } else {
            # Leave unchanged if not found.
            output = output substr(line, rstart, RLENGTH)
        }
        pos = rstart + RLENGTH
    }
    # Append the remainder of the line.
    output = output substr(line, pos)
    print output
}
AWK_EOF

    mv "$tmp_file" "$file"
}

# Process all files in CONFIG_DIR
while IFS= read -r -d '' file; do
    process_file "$file"
done < <(find "$CONFIG_DIR" -type f -print0)

# Process server.properties
if [[ -n "$SERVER_PROPERTIES" && -f "$SERVER_PROPERTIES" ]]; then
    process_file "$SERVER_PROPERTIES"
fi

echo "Environment variable substitution complete."

# --- Start the Server ---
if [ "$MODLOADER" == "forge" ]; then
    echo "Starting Forge server..."
    FORGE_DIR=$(ls -dv libraries/net/minecraftforge/forge/*/ | tail -n1)
    java -Xms"${MEM_MIN}M" -Xmx"${MEM_MAX}M" @"${FORGE_DIR}unix_args.txt" "$@" nogui
elif [ "$MODLOADER" = "neoforge" ]; then
    echo "Starting NeoForge server"
    NEOFORGE_DIR=$(ls -dv libraries/net/neoforged/neoforge/*/ | tail -n1)
    java -Xms"${MEM_MIN}M" -Xmx"${MEM_MAX}M" @"${NEOFORGE_DIR}unix_args.txt" "$@" nogui
elif [ "$MODLOADER" == "quilt" ]; then
    echo "Starting Quilt server..."
    java -Xms"${MEM_MIN}M" -Xmx"${MEM_MAX}M" -jar quilt-server-launch.jar nogui
else
    echo "Starting the server..."
    java -Xms"${MEM_MIN}M" -Xmx"${MEM_MAX}M" -jar server.jar nogui
fi



