#!/bin/bash
#
# validate_jsonl.sh - Verify JSONL files in the data folder for Gemini fine-tuning
#
# Usage: ./scripts/validate_jsonl.sh [file.jsonl]
#   If no file is specified, validates all .jsonl files in the data/ folder.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$REPO_ROOT/data"

# Counters
total_files=0
passed_files=0
failed_files=0
total_lines=0
failed_lines=0

# Function to print colored output
print_status() {
    local status="$1"
    local message="$2"
    case "$status" in
        "pass") echo -e "${GREEN}✓${NC} $message" ;;
        "fail") echo -e "${RED}✗${NC} $message" ;;
        "warn") echo -e "${YELLOW}⚠${NC} $message" ;;
        "info") echo -e "  $message" ;;
    esac
}

# Function to validate a single JSON line
validate_line() {
    local line="$1"
    local line_num="$2"
    local file="$3"
    local errors=""

    # Skip empty lines
    if [ -z "$line" ]; then
        return 0
    fi

    # Check if line is valid JSON
    if ! echo "$line" | jq empty 2>/dev/null; then
        echo "Line $line_num: Invalid JSON syntax"
        return 1
    fi

    # Check for required 'contents' field
    if ! echo "$line" | jq -e '.contents' >/dev/null 2>&1; then
        errors="${errors}Line $line_num: Missing required field 'contents'\n"
    fi

    # Validate 'contents' structure (should be an array)
    if echo "$line" | jq -e '.contents' >/dev/null 2>&1; then
        if ! echo "$line" | jq -e '.contents | type == "array"' >/dev/null 2>&1; then
            errors="${errors}Line $line_num: 'contents' must be an array\n"
        else
            # Check that contents array has at least one item
            contents_len=$(echo "$line" | jq '.contents | length')
            if [ "$contents_len" -eq 0 ]; then
                errors="${errors}Line $line_num: 'contents' array is empty\n"
            fi

            # Validate each content item has 'role' and 'parts'
            invalid_contents=$(echo "$line" | jq -r '.contents | to_entries[] | select(.value.role == null or .value.parts == null) | .key')
            if [ -n "$invalid_contents" ]; then
                for idx in $invalid_contents; do
                    errors="${errors}Line $line_num: contents[$idx] missing 'role' or 'parts'\n"
                done
            fi

            # Validate 'parts' is an array with 'text' field
            # For each content item, check if parts is an array and each part has a text field
            # Output format: "content_index:part_index" or "content_index:not_array"
            invalid_parts=$(echo "$line" | jq -r '
                .contents | to_entries[] |
                .key as $content_idx |
                .value.parts |
                if type == "array" then
                    to_entries[] | select(.value.text == null) | "\($content_idx):\(.key)"
                else
                    "\($content_idx):not_array"
                end
            ' 2>/dev/null || echo "")
            if [ -n "$invalid_parts" ]; then
                for item in $invalid_parts; do
                    if [[ "$item" == *":not_array"* ]]; then
                        idx="${item%%:*}"
                        errors="${errors}Line $line_num: contents[$idx].parts must be an array\n"
                    else
                        idx="${item%%:*}"
                        pidx="${item##*:}"
                        errors="${errors}Line $line_num: contents[$idx].parts[$pidx] missing 'text' field\n"
                    fi
                done
            fi
        fi
    fi

    # Validate 'systemInstruction' if present (optional field)
    if echo "$line" | jq -e '.systemInstruction' >/dev/null 2>&1; then
        # Check systemInstruction has 'role' and 'parts'
        if ! echo "$line" | jq -e '.systemInstruction.role' >/dev/null 2>&1; then
            errors="${errors}Line $line_num: 'systemInstruction' missing 'role' field\n"
        fi
        if ! echo "$line" | jq -e '.systemInstruction.parts' >/dev/null 2>&1; then
            errors="${errors}Line $line_num: 'systemInstruction' missing 'parts' field\n"
        else
            # Validate parts array has text
            if ! echo "$line" | jq -e '.systemInstruction.parts | type == "array"' >/dev/null 2>&1; then
                errors="${errors}Line $line_num: 'systemInstruction.parts' must be an array\n"
            fi
        fi
    fi

    if [ -n "$errors" ]; then
        echo -e "$errors"
        return 1
    fi

    return 0
}

# Function to validate a single file
validate_file() {
    local file="$1"
    local file_errors=0
    local file_lines=0

    if [ ! -f "$file" ]; then
        print_status "fail" "File not found: $file"
        return 1
    fi

    echo ""
    echo "Validating: $file"
    echo "----------------------------------------"

    # Read file line by line
    local line_num=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        file_lines=$((file_lines + 1))

        # Skip empty or whitespace-only lines
        if [[ "$line" =~ ^[[:space:]]*$ ]]; then
            continue
        fi

        # Validate line and capture errors
        local validation_errors
        if ! validation_errors=$(validate_line "$line" "$line_num" "$file") || [ -n "$validation_errors" ]; then
            file_errors=$((file_errors + 1))
            while IFS= read -r error_line; do
                [ -n "$error_line" ] && print_status "fail" "$error_line"
            done <<< "$validation_errors"
        fi
    done < "$file"

    total_lines=$((total_lines + file_lines))

    if [ "$file_errors" -eq 0 ]; then
        print_status "pass" "All $file_lines lines valid"
        return 0
    else
        failed_lines=$((failed_lines + file_errors))
        print_status "fail" "$file_errors of $file_lines lines have errors"
        return 1
    fi
}

# Main execution
main() {
    echo "========================================"
    echo "  JSONL Validator for Gemini Fine-tuning"
    echo "========================================"

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        print_status "fail" "jq is required but not installed. Please install jq."
        exit 1
    fi

    local files_to_validate=()

    # If a file argument is provided, validate only that file
    if [ $# -gt 0 ]; then
        for arg in "$@"; do
            if [ -f "$arg" ]; then
                files_to_validate+=("$arg")
            elif [ -f "$DATA_DIR/$arg" ]; then
                files_to_validate+=("$DATA_DIR/$arg")
            else
                print_status "fail" "File not found: $arg"
                exit 1
            fi
        done
    else
        # Find all .jsonl files in the data directory
        local found_files
        found_files=$(find "$DATA_DIR" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null)
        if [ -n "$found_files" ]; then
            while IFS= read -r file; do
                [ -n "$file" ] && files_to_validate+=("$file")
            done <<< "$found_files"
        fi

        if [ ${#files_to_validate[@]} -eq 0 ]; then
            print_status "warn" "No .jsonl files found in $DATA_DIR"
            exit 0
        fi
    fi

    # Validate each file
    for file in "${files_to_validate[@]}"; do
        total_files=$((total_files + 1))
        if validate_file "$file"; then
            passed_files=$((passed_files + 1))
        else
            failed_files=$((failed_files + 1))
        fi
    done

    # Print summary
    echo ""
    echo "========================================"
    echo "  Summary"
    echo "========================================"
    echo "Files checked: $total_files"
    echo "Files passed:  $passed_files"
    echo "Files failed:  $failed_files"
    echo "Total lines:   $total_lines"
    echo "Failed lines:  $failed_lines"
    echo ""

    if [ "$failed_files" -gt 0 ]; then
        print_status "fail" "Validation failed!"
        exit 1
    else
        print_status "pass" "All validations passed!"
        exit 0
    fi
}

main "$@"
