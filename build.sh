#!/bin/bash

set -euo pipefail

#=============================#
#        CONFIG SECTION       #
#=============================#

# Set kernel directory to current working directory
KERNEL_DIR="$(pwd)"

# Set output directory for the build
OUT_DIR="$KERNEL_DIR/out"

# Path to compiled kernel image directory
KERNEL_IMAGE_DIR="$OUT_DIR/arch/arm64/boot"

# Path to kernel image
KERNEL_IMAGE="$KERNEL_IMAGE_DIR/Image.gz-dtb"

# Path to clang
CLANGDIR="/workspace"

# Codename device
CODENAME="aurora_kddi"

# Defconfig file for building
CONFIG_NAME="tama_"$CODENAME"_defconfig"

# AnyKernel3 repository and branch
ANYKERNEL_REPO="https://github.com/Sorayukii/AnyKernel3"
ANYKERNEL_BRANCH="$CODENAME"
ANYKERNEL_DIR="$KERNEL_DIR/AnyKernel3"

# Kernel flashable file name
KERNEL_FLASH_NAME="Stardust_$CODENAME"

# Kernel source branch and latest commit id
KERNEL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
KERNEL_COMMIT_ID=$(git rev-parse --short=7 HEAD)

# Telegram bot token and group chat id
BOT_TOKEN="your_bot_token"
CHAT_ID="your_gc_id"

# Log file path
LOG_FILE="$KERNEL_DIR/build.log"

#=============================#
#     TELEGRAM FUNCTIONS     #
#=============================#

# Escape characters for markdown-v2 formatting in telegram
escape_markdown_v2() { 
    echo "$1" | sed -e 's/\\/\\\\/g' -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/~/\\~/g' -e 's/`/\\`/g' -e 's/>/\\>/g' -e 's/#/\\#/g' -e 's/+/\\+/g' -e 's/-/\\-/g' -e 's/=/\\=/g' -e 's/|/\\|/g' -e 's/{/\\{/g' -e 's/}/\\}/g';
}

# Send a text message to telegram
send_telegram_message() {
    local MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$MESSAGE"
}

# Send a file to telegram
send_telegram_file() {
    local FILE_PATH="$1"
    local FILE_NAME=$(basename "$FILE_PATH")
    local ESCAPED_NAME=$(escape_markdown_v2 "$FILE_NAME")
    local CAPTION="\`$ESCAPED_NAME\`"

    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
        -F "chat_id=$CHAT_ID" \
        -F "document=@$FILE_PATH" \
        -F "caption=$CAPTION" \
        -F "parse_mode=MarkdownV2"
}

#=============================#
#      STOP HANDLING         #
#=============================#

# Handle script interruption (SIGINT or error)
stop_handler() {
    send_telegram_message "⚠️ Compilation was unexpectedly stopped!"
    [ -f "$LOG_FILE" ] && send_telegram_file "$LOG_FILE"
    exit 1
}

# Trap interrupt and error signals
trap stop_handler ERR INT

#=============================#
#         START BUILD         #
#=============================#

# Notify build start
send_telegram_message "🔨 Starting kernel compilation for $CONFIG_NAME on branch $KERNEL_BRANCH..."

# Export environment variables for kernel build
export KBUILD_BUILD_USER=kanonify
export KBUILD_BUILD_HOST=android_build
export PATH="$CLANGDIR/bin:$PATH"

# Clean up previous build
rm -f "$LOG_FILE"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Generate defconfig
make O="$OUT_DIR" ARCH=arm64 "$CONFIG_NAME"

# Compile the kernel
make -j"$(nproc --all)" \
    O="$OUT_DIR" \
    ARCH=arm64 \
    CC=clang \
    LD=ld.lld \
    AR=llvm-ar \
    AS=llvm-as \
    NM=llvm-nm \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    OBJSIZE=llvm-size \
    READELF=llvm-readelf \
    STRIP=llvm-strip \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- 2>&1 | tee -a "$LOG_FILE"

# Store build result
BUILD_RESULT=${PIPESTATUS[0]}

# If compilation fails, notify and exit
if [ "$BUILD_RESULT" -ne 0 ]; then
    send_telegram_message "❌ Compilation failed!"
    [ -f "$LOG_FILE" ] && send_telegram_file "$LOG_FILE"
    exit 1
fi

#=============================#
#      PATCH KPM IF ENABLED   #
#=============================#

# Patch kpm only if CONFIG_KPM=y
if grep -q "^CONFIG_KPM=y" "$OUT_DIR/.config"; then
    cd "$KERNEL_IMAGE_DIR"

    # Download patch_linux from latest release
    PATCH_URL="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download/patch_linux"
    if ! curl -L -o patch_linux "$PATCH_URL"; then
        send_telegram_message "❌ Failed to download patch_linux"
        exit 1
    fi

    # Make patch executable and run
    chmod +x patch_linux
    if ! ./patch_linux; then
        send_telegram_message "❌ Failed to apply patch"
        exit 1
    fi

    # Replace Image with patched oImage
    if [ -f "oImage" ]; then
        rm -f Image Image.gz-dtb
        mv oImage Image
    else
        send_telegram_message "❌ Patching failed - oImage not found"
        exit 1
    fi

    # Compress and append DTBs
    gzip -c Image > Image.gz
    cat Image.gz dts/*/*.dtb > Image.gz-dtb

    # Back to working directory
    cd "$KERNEL_DIR"
fi

#=============================#
#     CREATE FLASHABLE ZIP    #
#=============================#

# If kernel image exists, package it
if [ -f "$KERNEL_IMAGE" ]; then

    # Clone AnyKernel3 if it doesn't exist
    if [ ! -d "$ANYKERNEL_DIR" ]; then
        git clone "$ANYKERNEL_REPO" "$ANYKERNEL_DIR"
    fi

    # Ensure correct branch
    cd "$ANYKERNEL_DIR"
    git fetch origin
    git checkout "$ANYKERNEL_BRANCH"
    cd "$KERNEL_DIR"

    # Copy compiled kernel image to AnyKernel
    cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/Image.gz-dtb"

    # Create flashable zip
    cd "$ANYKERNEL_DIR"
    ZIP_NAME="${KERNEL_FLASH_NAME}-$(date +%Y%m%d)-${KERNEL_COMMIT_ID}.zip"
    zip -r9 "../$ZIP_NAME" ./* > /dev/null
    cd "$KERNEL_DIR"

    # Send zip and log file to telegram
    send_telegram_file "$ZIP_NAME"
    send_telegram_file "$LOG_FILE"
    send_telegram_message "✅ Compilation completed, Flashable zip is ready."

# If kernel image doesn't exists, notify and exit
else
    send_telegram_message "❌ Build succeeded, but kernel image not found!"
    send_telegram_file "$LOG_FILE"
fi
