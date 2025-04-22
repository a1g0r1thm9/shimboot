#!/bin/bash

#build the bootloader image

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh

print_help() {
  echo "Usage: ./build.sh output_path shim_path rootfs_dir"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  quiet - Don't use progress indicators which may clog up log files."
  echo "  arch  - Set this to 'arm64' to specify that the shim is for an ARM chromebook."
  echo "  name  - The name for the shimboot rootfs partition."
  echo "  luks  - Set this to 'true' to build an encrypted image. Currently not available on arm devices."
}

assert_root
assert_deps "cpio binwalk pcregrep realpath cgpt mkfs.ext4 mkfs.ext2 fdisk lz4"
assert_args "$3"
parse_args "$@"

output_path=$(realpath -m "${1}")
shim_path=$(realpath -m "${2}")
rootfs_dir=$(realpath -m "${3}")

quiet="${args['quiet']}"
arch="${args['arch']}"
bootloader_part_name="${args['name']}"
luks_enabled="${args['luks']}"

if [[ "$luks_enabled" == "true" && "$arch" == "arm64" ]]; then
  print_error "Uh-oh, you are trying to use luks2 encryption on an arm64 board. Unfortunately, rootfs encryption is not available on arm64-based boards at this time. :("
  exit
fi

if [ "$luks_enabled" = 'true' ]; then
  while true; do
      read -p "Enter the LUKS2 password for the image: " crypt_password
      read -p "Retype the password: " crypt_password_confirm
      if [ "$crypt_password" = "$crypt_password_confirm" ]; then
          break
      else
          echo "Passwords do not match. Please try again."
      fi
  done
  print_info "downloading shimboot-binaries"
  temp_shimboot_binaries="/tmp/shimboot-binaries.tar.gz"
  #grab latest release from sb-binaries - may need to rework this logic if my plans for multiarch shimboot-binaries go through
  #chunks the tar into /tmp before extracting cryptsetup, might cause issues on interrupt during extraction
  wget -qO- https://api.github.com/repos/ading2210/shimboot-binaries/releases/latest \
    | grep browser_download_url \
    | grep '' \
    | head -n1 \
    | cut -d '"' -f 4 \
    | xargs wget -O "$temp_shimboot_binaries"
  #extract cryptsetup and delete the archive
  tar -xf "$temp_shimboot_binaries" -C $(realpath -m "bootloader/bin/") "cryptsetup"
  rm "$temp_shimboot_binaries"
  chmod +x "$(realpath -m "bootloader/bin/")/cryptsetup"
fi

print_info "reading the shim image"
initramfs_dir=/tmp/shim_initramfs
kernel_img=/tmp/kernel.img
rm -rf $initramfs_dir $kernel_img
extract_initramfs_full $shim_path $initramfs_dir $kernel_img "$arch"

print_info "patching initramfs"
patch_initramfs $initramfs_dir

print_info "creating disk image"
rootfs_size=$(du -sm $rootfs_dir | cut -f 1)
rootfs_part_size=$(($rootfs_size * 12 / 10 + 5))
#create a 20mb bootloader partition
#rootfs partition is 20% larger than its contents
create_image "$output_path" 20 "$rootfs_part_size" "$bootloader_part_name"

print_info "creating loop device for the image"
image_loop=$(create_loop ${output_path})

print_info "creating partitions on the disk image"
create_partitions $image_loop $kernel_img $luks_enabled "$crypt_password"

print_info "copying data into the image"
populate_partitions "$image_loop" "$initramfs_dir" "$rootfs_dir" "$quiet" "$luks_enabled"
rm -rf $initramfs_dir $kernel_img

print_info "cleaning up loop devices"
losetup -d $image_loop
print_info "done"
