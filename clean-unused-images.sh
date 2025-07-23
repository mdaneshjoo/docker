#!/bin/bash

###############################################################################
# Script Name: clean-unused-images.sh
#
# Description:
#   This script removes all local Docker images that are *not referenced* 
#   in one or more specified Docker Compose files.
#
#   It extracts all `image:` declarations from each Compose file, 
#   consolidates the lists, compares them against locally available Docker images 
#   and deletes those that are not referenced in *any* Compose file.
#
#   Shows storage usage information for items to be deleted, helping you understand
#   how much disk space will be freed.
#
# Usage:
#   ./clean-unused-images.sh [compose-file1] [compose-file2] ...
#   ./clean-unused-images.sh --ignore "image1,image2" 
#
#   - If no arguments are provided, defaults to `docker-compose.yml`.
#   - Use --ignore to specify exact images to preserve (comma-separated).
#   - When --ignore is used, compose file processing is DISABLED.
#   - Images without tags automatically get :latest added.
#   - Prompts before deletion.
#
# Requirements:
#   - Docker CLI
#   - Docker Compose (v2+)
#
# Warning:
#   - This only considers images explicitly declared in `image:` keys.
#   - Does not detect images built from `build:` context unless `image:` is also set.
#   - Ensure the images are not needed by any other local containers or projects.
#
###############################################################################

set -euo pipefail

# Parse command line arguments
IGNORE_IMAGES=""
COMPOSE_FILES=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --ignore)
      IGNORE_IMAGES="$2"
      shift 2
      ;;
    --ignore=*)
      IGNORE_IMAGES="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--ignore \"image1,image2\"] [compose-file1] [compose-file2] ..."
      echo ""
      echo "Options:"
      echo "  --ignore IMAGES    Comma-separated list of exact images to preserve"
      echo "                     When used, compose file processing is DISABLED"
      echo "  -h, --help         Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                                       # Use docker-compose.yml"
      echo "  $0 docker-compose.prod.yml              # Use specific compose file"  
      echo "  $0 --ignore \"nginx:latest,redis:6\"      # Preserve these exact images (ignore compose)"
      echo "  $0 --ignore \"localstack/localstack\"     # Preserve without tag (becomes :latest)"
      echo ""
      echo "Note: This script only manages Docker images, not volumes."
      exit 0
      ;;
    *)
      COMPOSE_FILES+=("$1")
      shift
      ;;
  esac
done

# Use provided files or fallback to default
if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
  COMPOSE_FILES=("docker-compose.yml")
fi

used_images_set=()

echo "🔍 Scanning Compose files for used images..."

# Only process compose files if --ignore flag is NOT used
if [[ -z "$IGNORE_IMAGES" ]]; then
  for file in "${COMPOSE_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
      echo "❌ File not found: $file"
      exit 1
    fi

    echo "➡️  Parsing images from $file ..."
    
    # Extract images
    config_output=$(docker compose -f "$file" config --profile all 2>/dev/null || docker compose -f "$file" config)
    if [[ $? -ne 0 ]]; then
      echo "❌ Failed to parse docker-compose file: $file"
      exit 1
    fi
    
    images=$(echo "$config_output" | grep 'image:' | awk '{print $2}' || true)
    
    if [[ -n "$images" ]]; then
      # Normalize image names to include :latest tag if missing
      while IFS= read -r image; do
        if [[ "$image" != *":"* ]]; then
          image="$image:latest"
        fi
        used_images_set+=("$image")
      done <<< "$images"
    fi
  done
else
  echo "🔒 Ignore flag detected - skipping compose file processing"
  echo "➡️  Only manually ignored images will be preserved"
fi

# Process manually ignored images
if [[ -n "$IGNORE_IMAGES" ]]; then
  echo "🔒 Processing manually ignored images..."
  # Split comma-separated list and add to used_images_set
  IFS=',' read -ra IGNORE_ARRAY <<< "$IGNORE_IMAGES"
  for ignore_image in "${IGNORE_ARRAY[@]}"; do
    # Trim whitespace
    ignore_image=$(echo "$ignore_image" | xargs)
    # Add :latest tag if missing
    if [[ "$ignore_image" != *":"* && -n "$ignore_image" ]]; then
      ignore_image="$ignore_image:latest"
    fi
    if [[ -n "$ignore_image" ]]; then
      used_images_set+=("$ignore_image")
    fi
  done
fi

# Deduplicate the list of used images
if [[ ${#used_images_set[@]} -gt 0 ]]; then
  used_images=$(printf "%s\n" "${used_images_set[@]}" | sort -u | grep -v '^$' || true)
else
  used_images=""
fi

# Show what images will be preserved (for verification)
if [[ -n "$used_images" ]]; then
  echo "✅ Images that will be PRESERVED:"
  
  if [[ -z "$IGNORE_IMAGES" ]]; then
    # Show compose file images when --ignore is NOT used
    echo "  📄 From compose file(s):"
    for file in "${COMPOSE_FILES[@]}"; do
      if [[ -f "$file" ]]; then
        config_output=$(docker compose -f "$file" config --profile all 2>/dev/null || docker compose -f "$file" config)
        file_images=$(echo "$config_output" | grep 'image:' | awk '{print $2}' || true)
        if [[ -n "$file_images" ]]; then
          while IFS= read -r image; do
            if [[ "$image" != *":"* ]]; then
              image="$image:latest"
            fi
            echo "    🔒 $image"
          done <<< "$file_images"
        fi
      fi
    done
  else
    # Show manually ignored images when --ignore IS used
    echo "  🛡️  Manually ignored (compose files skipped):"
    IFS=',' read -ra IGNORE_ARRAY <<< "$IGNORE_IMAGES"
    for ignore_image in "${IGNORE_ARRAY[@]}"; do
      ignore_image=$(echo "$ignore_image" | xargs)
      if [[ "$ignore_image" != *":"* && -n "$ignore_image" ]]; then
        ignore_image="$ignore_image:latest"
      fi
      if [[ -n "$ignore_image" ]]; then
        echo "    🔒 $ignore_image"
      fi
    done
  fi
  echo
fi

# Get all local images
all_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | sort -u)

# Determine images not used in any Compose file
if [[ -n "$IGNORE_IMAGES" ]]; then
  # Show detailed matching process for --ignore flag
  echo "🔍 Checking images against ignore list..."
  while IFS= read -r image; do
    if echo "$used_images" | grep -Fxq "$image"; then
      echo "  ✅ Preserving: $image (found in ignore list)"
    fi
  done <<< "$all_images"
fi

unused_images=$(comm -23 <(echo "$all_images") <(echo "$used_images"))

# Check if there's anything to clean up
if [[ -z "$unused_images" ]]; then
  echo "✅ No unused images found. Nothing to remove."
  exit 0
fi

# Function to convert size to bytes for calculation
size_to_bytes() {
  local size=$1
  local num=$(echo "$size" | sed 's/[^0-9.]//g')
  local unit=$(echo "$size" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
  
  # Remove decimal part for bash arithmetic
  local int_num=${num%.*}
  if [[ -z "$int_num" ]]; then int_num=0; fi
  
  case $unit in
    "KB"|"K") echo $((int_num * 1024)) ;;
    "MB"|"M") echo $((int_num * 1024 * 1024)) ;;
    "GB"|"G") echo $((int_num * 1024 * 1024 * 1024)) ;;
    "TB"|"T") echo $((int_num * 1024 * 1024 * 1024 * 1024)) ;;
    "B"|"") echo "$int_num" ;;
    *) echo "0" ;;
  esac
}

# Function to convert bytes to human readable format
bytes_to_human() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    echo "$((bytes / 1073741824))GB"
  elif (( bytes >= 1048576 )); then
    echo "$((bytes / 1048576))MB"
  elif (( bytes >= 1024 )); then
    echo "$((bytes / 1024))KB"
  else
    echo "${bytes}B"
  fi
}

# Count items and calculate storage usage
image_count=0
total_image_size_bytes=0

if [[ -n "$unused_images" ]]; then
  image_count=$(echo "$unused_images" | wc -l)
  
  echo "📊 Calculating storage usage..."
  
  # Get image sizes
  while IFS= read -r image; do
    size=$(docker images --format "{{.Size}}" --filter "reference=$image" | head -1)
    if [[ -n "$size" ]]; then
      size_bytes=$(size_to_bytes "$size")
      total_image_size_bytes=$((total_image_size_bytes + size_bytes))
    fi
  done <<< "$unused_images"
fi

total_size_bytes=$((total_image_size_bytes))

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                        🚨 DELETION SUMMARY 🚨                    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo

echo "📊 Items to be deleted:"
echo "  • Images: $image_count ($(bytes_to_human $total_image_size_bytes))"
echo "  • Total items: $image_count"
echo "  • Total storage to free: $(bytes_to_human $total_size_bytes)"
echo

if [[ -n "$unused_images" ]]; then
  echo "📦 Docker Images to be DELETED ($image_count - $(bytes_to_human $total_image_size_bytes)):"
  echo "──────────────────────────────────────────────────────────────────"
  while IFS= read -r image; do
    size=$(docker images --format "{{.Size}}" --filter "reference=$image" | head -1)
    printf "  ❌ %-50s %s\n" "$image" "$size"
  done <<< "$unused_images"
  echo
fi

echo "⚠️  WARNING: This action is IRREVERSIBLE!"
echo "⚠️  Make sure these resources are not needed by other projects!"
echo

# First confirmation
read -p "❓ Do you want to proceed with deletion? Type 'yes' for normal deletion or 'force' for force deletion: " confirm
if [[ "$confirm" != "yes" && "$confirm" != "force" ]]; then
  echo "❌ Aborted by user."
  exit 0
fi

echo
echo "🔥 Starting cleanup process..."
echo

# Remove the unused images
if [[ -n "$unused_images" ]]; then
  
  if [[ "$confirm" == "force" ]]; then
    # Force delete all images immediately
    echo "💥 Force deleting ALL $image_count unused images..."
    successfully_deleted=0
    
    # Convert to array for proper processing
    readarray -t image_array <<< "$unused_images"
    
    for image in "${image_array[@]}"; do
      echo "  💥 Force deleting: $image"
      if docker rmi -f "$image" 2>/dev/null; then
        successfully_deleted=$((successfully_deleted + 1))
      else
        error_output=$(docker rmi -f "$image" 2>&1)
        if [[ "$error_output" == *"invalid reference format"* ]]; then
          echo "    ⚠️  Invalid image format (e.g., <none>:<none>) - skipping"
        else
          echo "    ❌ Even force deletion failed for: $image"
          echo "    ❌ Error: $(echo "$error_output" | head -1)"
        fi
      fi
    done
    
    echo "✅ Force deletion complete."
    echo "📊 Successfully deleted: $successfully_deleted images"
    
  else
    # Normal deletion process with two-stage approach
    echo "🗑️  Removing $image_count unused images..."
    
    failed_images=()
    successfully_deleted=0
    
    # Convert to array for proper processing
    readarray -t image_array <<< "$unused_images"
    
    for image in "${image_array[@]}"; do
      echo "  🗑️  Deleting image: $image"
      if docker rmi "$image" 2>/dev/null; then
        successfully_deleted=$((successfully_deleted + 1))
      else
        # Check if it's a container conflict (needs force) or invalid format
        error_output=$(docker rmi "$image" 2>&1)
        if [[ "$error_output" == *"must force"* ]]; then
          echo "    ⚠️  In use by container - will ask for force deletion"
          failed_images+=("$image")
        elif [[ "$error_output" == *"invalid reference format"* ]]; then
          echo "    ⚠️  Invalid image format (e.g., <none>:<none>) - skipping"
        else
          echo "    ⚠️  Failed to remove: $image"
          echo "    ❌  Error: $(echo "$error_output" | head -1)"
        fi
      fi
    done
    
    # Handle force deletion if there are images in use by containers
    if [[ ${#failed_images[@]} -gt 0 ]]; then
      echo
      echo "⚠️  Some images are in use by containers and require force deletion:"
      printf '  🔒 %s\n' "${failed_images[@]}"
      echo
      echo "🚨 WARNING: Force deletion will remove images even if containers are using them!"
      echo "🚨 This may cause running containers to malfunction!"
      echo
      
      read -p "❓ Do you want to FORCE delete these images? Type 'force' or 'yes' to continue: " force_confirm
      if [[ "$force_confirm" == "force" || "$force_confirm" == "yes" ]]; then
        echo
        echo "💥 Force deleting images in use by containers..."
        for image in "${failed_images[@]}"; do
          echo "  💥 Force deleting: $image"
          if docker rmi -f "$image"; then
            successfully_deleted=$((successfully_deleted + 1))
          else
            echo "    ❌ Even force deletion failed for: $image"
          fi
        done
      else
        echo "❌ Force deletion cancelled. Images in use by containers were preserved."
      fi
    fi
    
    echo "✅ Images cleanup complete."
    echo "📊 Successfully deleted: $successfully_deleted images"
  fi
  echo
fi

echo "✅ Full cleanup complete!"
echo "📊 Summary: Processed $image_count images."
