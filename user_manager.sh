#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
MENU_WIDTH=78

REQUIRED_COMMANDS=(
    bash
    sudo
    useradd
    usermod
    userdel
    passwd
    chage
    getent
    id
    groups
    groupadd
    groupmod
    groupdel
    gpasswd
    chsh
)

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_MAGENTA=''
    C_CYAN=''
fi

trap 'printf "\n"; exit 130' INT

repeat_char() {
    local count="$1"
    local char="${2:-=}"

    printf '%*s' "$count" '' | tr ' ' "$char"
}

center_text() {
    local text="$1"
    local width="${2:-$MENU_WIDTH}"
    local padding=0

    if (( ${#text} < width )); then
        padding=$(( (width - ${#text}) / 2 ))
    fi

    printf '%*s%s\n' "$padding" '' "$text"
}

print_banner() {
    local line

    line="$(repeat_char "$MENU_WIDTH" '=')"
    if [[ -t 1 ]]; then
        clear
    fi

    printf '%s%s%s\n' "$C_BLUE" "$line" "$C_RESET"
    center_text "${C_BOLD}${C_CYAN}FEDORA ACCOUNT CONTROL${C_RESET}" "$MENU_WIDTH"
    center_text "${C_DIM}Manage users, groups and access from one menu.${C_RESET}" "$MENU_WIDTH"
    printf '%s%s%s\n\n' "$C_BLUE" "$line" "$C_RESET"
}

info() {
    printf '%s[info]%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2
}

success() {
    printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2
}

warn() {
    printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

error() {
    printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

pause() {
    local _

    printf '\nPress Enter to continue...'
    IFS= read -r _ || exit 0
}

read_input() {
    local prompt="$1"
    local reply

    printf '%s' "$prompt" >&2
    IFS= read -r reply || exit 0
    printf '%s' "$reply"
}

trim() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

prompt_required() {
    local prompt="$1"
    local reply

    while :; do
        reply="$(trim "$(read_input "$prompt")")"
        if [[ -n "$reply" ]]; then
            printf '%s' "$reply"
            return 0
        fi
        warn "A value is required."
    done
}

prompt_default() {
    local label="$1"
    local default_value="$2"
    local reply

    reply="$(trim "$(read_input "$label [$default_value]: ")")"
    if [[ -z "$reply" ]]; then
        printf '%s' "$default_value"
        return 0
    fi
    printf '%s' "$reply"
}

confirm() {
    local prompt="$1"
    local default_answer="${2:-Y}"
    local options='[Y/n]'
    local reply

    if [[ "$default_answer" =~ ^[Nn]$ ]]; then
        options='[y/N]'
    fi

    while :; do
        reply="$(trim "$(read_input "$prompt $options ")")"
        if [[ -z "$reply" ]]; then
            [[ "$default_answer" =~ ^[Yy]$ ]]
            return $?
        fi

        case "$reply" in
            y|Y|yes|YES)
                return 0
                ;;
            n|N|no|NO)
                return 1
                ;;
        esac

        warn "Answer with y or n."
    done
}

normalize_csv() {
    local value="${1// /}"

    value="${value#,}"
    value="${value%,}"
    while [[ "$value" == *',,'* ]]; do
        value="${value//,,/,}"
    done

    printf '%s' "$value"
}

validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

validate_group_name() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

user_exists() {
    getent passwd "$1" >/dev/null 2>&1
}

group_exists() {
    getent group "$1" >/dev/null 2>&1
}

user_home() {
    getent passwd "$1" | cut -d: -f6
}

user_shell() {
    getent passwd "$1" | cut -d: -f7
}

user_comment() {
    getent passwd "$1" | cut -d: -f5
}

group_gid() {
    getent group "$1" | cut -d: -f3
}

group_explicit_members_csv() {
    getent group "$1" | cut -d: -f4
}

group_primary_members_csv() {
    local group_name="$1"
    local gid

    gid="$(group_gid "$group_name")"
    getent passwd |
    awk -F: -v gid="$gid" 'BEGIN { sep = "" } $4 == gid { printf "%s%s", sep, $1; sep = "," }'
}

group_all_members_csv() {
    local group_name="$1"
    local explicit_members
    local primary_members

    explicit_members="$(group_explicit_members_csv "$group_name")"
    primary_members="$(group_primary_members_csv "$group_name")"

    {
        tr ',' '\n' <<< "$explicit_members"
        tr ',' '\n' <<< "$primary_members"
    } |
    awk 'NF && !seen[$0]++ { out = out ? out "," $0 : $0 } END { printf "%s", out }'
}

is_protected_group() {
    case "$1" in
        root|wheel)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

user_in_group() {
    id -nG "$1" | tr ' ' '\n' | grep -qx "$2"
}

ensure_shell_valid() {
    local shell_path="$1"

    [[ -x "$shell_path" ]] || return 1
    grep -qxF "$shell_path" /etc/shells
}

ensure_groups_exist() {
    local groups_csv="$1"
    local group_name
    local group_array=()

    [[ -z "$groups_csv" ]] && return 0
    IFS=',' read -r -a group_array <<< "$groups_csv"

    for group_name in "${group_array[@]}"; do
        group_name="$(trim "$group_name")"
        [[ -z "$group_name" ]] && continue

        if group_exists "$group_name"; then
            continue
        fi

        if confirm "Group '$group_name' does not exist. Create it now?" Y; then
            groupadd "$group_name"
            success "Created group '$group_name'."
        else
            warn "Skipping change until group '$group_name' exists."
            return 1
        fi
    done
}

list_users_table() {
    getent passwd |
    awk -F: '($3 == 0) || ($3 >= 1000 && $1 != "nobody") {printf "%-18s uid=%-5s home=%-28s shell=%s\n", $1, $3, $6, $7}' |
    sort -k2,2n
}

list_users_screen() {
    print_banner
    printf '%sAvailable login-capable users%s\n\n' "$C_BOLD" "$C_RESET"
    list_users_table
    printf '\n'
}

list_groups_table() {
    getent group |
    sort -t: -k3,3n |
    awk -F: '{ members = $4; if (members == "") members = "-"; printf "%-20s gid=%-5s members=%s\n", $1, $3, members }'
}

list_groups_screen() {
    print_banner
    printf '%sAvailable groups%s\n\n' "$C_BOLD" "$C_RESET"
    list_groups_table
    printf '\n'
}

select_existing_user() {
    local username

    list_users_screen >&2
    while :; do
        username="$(trim "$(read_input "Username to manage: ")")"
        if user_exists "$username"; then
            printf '%s' "$username"
            return 0
        fi
        warn "User '$username' does not exist."
    done
}

select_existing_group() {
        local group_name

        list_groups_screen >&2
        while :; do
                group_name="$(trim "$(read_input "Group to manage: ")")"
                if group_exists "$group_name"; then
                        printf '%s' "$group_name"
                        return 0
                fi
                warn "Group '$group_name' does not exist."
        done
}

print_usage() {
    cat <<EOF
Usage:
    $SCRIPT_NAME                 Open the interactive menu.
    $SCRIPT_NAME NAME            Open a user menu for NAME, or a group menu if only the group exists.
    $SCRIPT_NAME --group NAME    Open the management menu for an existing group.
    $SCRIPT_NAME --list          Print user accounts and exit.
    $SCRIPT_NAME --groups        Print groups and exit.
    $SCRIPT_NAME --help          Show this help.

Notes:
  - The script will request sudo when a privileged action is needed.
  - Fedora grants admin rights through the 'wheel' group.
    - Protected groups like 'root' and 'wheel' can be managed, but not renamed or deleted.
EOF
}

ensure_commands() {
    local missing=()
    local command_name

    for command_name in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing+=("$command_name")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

require_root() {
    if (( EUID == 0 )); then
        return 0
    fi

    info "Root privileges are required for account changes."
    exec sudo --preserve-env=TERM "$SCRIPT_PATH" "$@"
}

password_state_label() {
    case "$1" in
        P)
            printf 'password set'
            ;;
        L)
            printf 'locked'
            ;;
        NP)
            printf 'no password'
            ;;
        LK)
            printf 'locked'
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

show_user_details() {
    local username="$1"
    local passwd_line
    local account_name
    local uid
    local gid
    local gecos
    local home_dir
    local shell_path
    local primary_group
    local all_groups
    local password_state
    local expiry_line

    if ! user_exists "$username"; then
        error "User '$username' does not exist."
        pause
        return 1
    fi

    passwd_line="$(getent passwd "$username")"
    IFS=':' read -r account_name _ uid gid gecos home_dir shell_path <<< "$passwd_line"
    primary_group="$(id -gn "$username")"
    all_groups="$(id -nG "$username")"
    password_state="$(passwd -S "$username" 2>/dev/null | awk '{print $2}')"
    expiry_line="$(chage -l "$username" 2>/dev/null | awk -F': ' '/^Account expires/ {print $2}')"
    expiry_line="${expiry_line:-never}"

    print_banner
    printf '%sUser profile: %s%s\n\n' "$C_BOLD" "$username" "$C_RESET"
    printf '  Username      : %s\n' "$account_name"
    printf '  UID / GID     : %s / %s\n' "$uid" "$gid"
    printf '  Primary group : %s\n' "$primary_group"
    printf '  Groups        : %s\n' "$all_groups"
    printf '  Home          : %s\n' "$home_dir"
    printf '  Shell         : %s\n' "$shell_path"
    printf '  Comment       : %s\n' "${gecos:-<empty>}"
    printf '  Password      : %s\n' "$(password_state_label "$password_state")"
    printf '  Expires       : %s\n' "$expiry_line"
    pause
}

prompt_new_username() {
    local username

    while :; do
        username="$(prompt_required "New username: ")"
        if ! validate_username "$username"; then
            warn "Use Linux-friendly names like devops, qa_user or mohamed-2."
            continue
        fi
        if user_exists "$username"; then
            warn "User '$username' already exists."
            continue
        fi
        printf '%s' "$username"
        return 0
    done
}

prompt_new_group_name() {
    local group_name

    while :; do
        group_name="$(prompt_required "New group name: ")"
        if ! validate_group_name "$group_name"; then
            warn "Use Linux-friendly group names like devops, qa_team or editors."
            continue
        fi
        if group_exists "$group_name"; then
            warn "Group '$group_name' already exists."
            continue
        fi
        printf '%s' "$group_name"
        return 0
    done
}

prompt_existing_or_new_group() {
    local label="$1"
    local group_name

    while :; do
        group_name="$(trim "$(read_input "$label")")"
        [[ -z "$group_name" ]] && warn "Group name is required." && continue

        if group_exists "$group_name"; then
            printf '%s' "$group_name"
            return 0
        fi

        if confirm "Group '$group_name' does not exist. Create it now?" Y; then
            groupadd "$group_name"
            success "Created group '$group_name'."
            printf '%s' "$group_name"
            return 0
        fi
    done
}

create_group_interactive() {
    local group_name
    local custom_gid
    local cmd=()

    print_banner
    printf '%sCreate a new Fedora group%s\n\n' "$C_BOLD" "$C_RESET"

    group_name="$(prompt_new_group_name)"
    while :; do
        custom_gid="$(trim "$(read_input "Custom GID (optional): ")")"
        if [[ -z "$custom_gid" || "$custom_gid" =~ ^[0-9]+$ ]]; then
            break
        fi
        warn "GID must be numeric."
    done

    cmd=(groupadd)
    [[ -n "$custom_gid" ]] && cmd+=(-g "$custom_gid")
    cmd+=("$group_name")
    "${cmd[@]}"
    success "Created group '$group_name'."

    if confirm "Add users to '$group_name' now?" N; then
        add_members_to_group "$group_name"
        return 0
    fi

    pause
}

create_user_interactive() {
    local username
    local full_name
    local home_dir
    local shell_path
    local extra_groups
    local create_home='yes'
    local grant_admin='no'
    local group_list=''
    local cmd=()

    print_banner
    printf '%sCreate a new Fedora user%s\n\n' "$C_BOLD" "$C_RESET"

    username="$(prompt_new_username)"
    full_name="$(trim "$(read_input "Full name/comment (optional): ")")"
    home_dir="$(prompt_default "Home directory" "/home/$username")"
    shell_path="$(prompt_default "Login shell" "/bin/bash")"

    if ! ensure_shell_valid "$shell_path"; then
        error "'$shell_path' is not a valid login shell listed in /etc/shells."
        pause
        return 1
    fi

    if confirm "Create the home directory automatically?" Y; then
        create_home='yes'
    else
        create_home='no'
    fi

    extra_groups="$(normalize_csv "$(trim "$(read_input "Extra groups (comma-separated, optional): ")")")"
    if confirm "Grant sudo privileges through the wheel group?" N; then
        grant_admin='yes'
        if [[ -z "$extra_groups" ]]; then
            group_list='wheel'
        elif [[ ",$extra_groups," == *",wheel,"* ]]; then
            group_list="$extra_groups"
        else
            group_list="$extra_groups,wheel"
        fi
    else
        group_list="$extra_groups"
    fi

    group_list="$(normalize_csv "$group_list")"
    ensure_groups_exist "$group_list" || {
        pause
        return 1
    }

    cmd=(useradd)
    if [[ "$create_home" == 'yes' ]]; then
        cmd+=(-m)
    else
        cmd+=(-M)
    fi
    cmd+=(-d "$home_dir" -s "$shell_path")
    [[ -n "$full_name" ]] && cmd+=(-c "$full_name")
    [[ -n "$group_list" ]] && cmd+=(-G "$group_list")
    cmd+=("$username")

    "${cmd[@]}"
    success "Created user '$username'."

    if [[ "$grant_admin" == 'yes' ]]; then
        success "Admin access enabled through the wheel group."
    fi

    if confirm "Set a password for '$username' now?" Y; then
        passwd "$username"
    fi

    pause
}

delete_user_account() {
    local username="$1"
    local confirmation
    local remove_home='no'
    local caller="${SUDO_USER:-}"
    local cmd=()

    if [[ "$username" == 'root' ]]; then
        warn "Refusing to delete the root account."
        pause
        return 1
    fi

    if [[ -n "$caller" && "$username" == "$caller" ]]; then
        warn "Refusing to delete the account that launched this session: '$username'."
        pause
        return 1
    fi

    print_banner
    warn "You are about to delete '$username'. This cannot be undone."
    if confirm "Also delete the home directory and mail spool?" N; then
        remove_home='yes'
    fi

    confirmation="$(trim "$(read_input "Type the username again to confirm: ")")"
    if [[ "$confirmation" != "$username" ]]; then
        warn "Confirmation did not match. Deletion cancelled."
        pause
        return 1
    fi

    cmd=(userdel)
    [[ "$remove_home" == 'yes' ]] && cmd+=(-r)
    cmd+=("$username")
    "${cmd[@]}"
    success "Deleted user '$username'."
    pause
    return 0
}

rename_user_account() {
    local username="$1"
    local new_username
    local old_home
    local primary_group

    old_home="$(user_home "$username")"
    primary_group="$(id -gn "$username")"

    while :; do
        new_username="$(prompt_required "New username: ")"
        if ! validate_username "$new_username"; then
            warn "Invalid username format."
            continue
        fi
        if user_exists "$new_username"; then
            warn "User '$new_username' already exists."
            continue
        fi
        break
    done

    usermod -l "$new_username" "$username"
    success "Renamed '$username' to '$new_username'."

    if command -v groupmod >/dev/null 2>&1 && [[ "$primary_group" == "$username" ]] && group_exists "$username"; then
        if confirm "Rename the matching primary group '$username' to '$new_username'?" Y; then
            groupmod -n "$new_username" "$username"
            success "Renamed group '$username' to '$new_username'."
        fi
    fi

    if [[ "$old_home" == "/home/$username" ]] && confirm "Move the home directory to '/home/$new_username'?" Y; then
        usermod -d "/home/$new_username" -m "$new_username"
        success "Moved the home directory to '/home/$new_username'."
    fi

    printf '%s' "$new_username"
}

set_user_password() {
    passwd "$1"
    success "Password updated for '$1'."
    pause
}

lock_user_account() {
    passwd -l "$1"
    success "Locked '$1'."
    pause
}

unlock_user_account() {
    passwd -u "$1"
    success "Unlocked '$1'."
    pause
}

grant_sudo_access() {
    local username="$1"

    if id -nG "$username" | tr ' ' '\n' | grep -qx 'wheel'; then
        warn "'$username' already has wheel access."
        pause
        return 0
    fi

    usermod -aG wheel "$username"
    success "Granted sudo access to '$username' via wheel."
    pause
}

revoke_sudo_access() {
    local username="$1"
    local primary_group

    primary_group="$(id -gn "$username")"
    if [[ "$primary_group" == 'wheel' ]]; then
        warn "'wheel' is the primary group for '$username'. Change the primary group first."
        pause
        return 1
    fi

    if ! id -nG "$username" | tr ' ' '\n' | grep -qx 'wheel'; then
        warn "'$username' is not in the wheel group."
        pause
        return 0
    fi

    gpasswd -d "$username" wheel
    success "Removed '$username' from the wheel group."
    pause
}

add_supplementary_groups() {
    local username="$1"
    local group_list

    group_list="$(normalize_csv "$(trim "$(read_input "Groups to add (comma-separated): ")")")"
    if [[ -z "$group_list" ]]; then
        warn "No groups were entered."
        pause
        return 1
    fi

    ensure_groups_exist "$group_list" || {
        pause
        return 1
    }

    usermod -aG "$group_list" "$username"
    success "Added '$username' to: $group_list"
    pause
}

remove_supplementary_groups() {
    local username="$1"
    local primary_group
    local current_groups
    local requested_groups
    local group_name
    local group_array=()

    primary_group="$(id -gn "$username")"
    current_groups="$(id -nG "$username")"

    print_banner
    printf '%sCurrent groups for %s%s\n\n' "$C_BOLD" "$username" "$C_RESET"
    printf '  %s\n\n' "$current_groups"

    requested_groups="$(normalize_csv "$(trim "$(read_input "Groups to remove (comma-separated): ")")")"
    if [[ -z "$requested_groups" ]]; then
        warn "No groups were entered."
        pause
        return 1
    fi

    IFS=',' read -r -a group_array <<< "$requested_groups"
    for group_name in "${group_array[@]}"; do
        group_name="$(trim "$group_name")"
        [[ -z "$group_name" ]] && continue

        if [[ "$group_name" == "$primary_group" ]]; then
            warn "Skipping '$group_name' because it is the primary group."
            continue
        fi

        if ! id -nG "$username" | tr ' ' '\n' | grep -qx "$group_name"; then
            warn "Skipping '$group_name' because '$username' is not a member."
            continue
        fi

        gpasswd -d "$username" "$group_name"
        success "Removed '$username' from '$group_name'."
    done

    pause
}

change_primary_group() {
    local username="$1"
    local group_name

    group_name="$(prompt_existing_or_new_group "New primary group: ")"
    usermod -g "$group_name" "$username"
    success "Primary group for '$username' is now '$group_name'."
    pause
}

change_login_shell() {
    local username="$1"
    local shell_path

    shell_path="$(prompt_default "New login shell" "$(user_shell "$username")")"
    if ! ensure_shell_valid "$shell_path"; then
        error "'$shell_path' is not a valid login shell listed in /etc/shells."
        pause
        return 1
    fi

    usermod -s "$shell_path" "$username"
    success "Shell for '$username' is now '$shell_path'."
    pause
}

move_home_directory() {
    local username="$1"
    local current_home
    local new_home

    current_home="$(user_home "$username")"
    new_home="$(prompt_default "New home directory" "$current_home")"

    if confirm "Move existing files to '$new_home'?" Y; then
        usermod -d "$new_home" -m "$username"
        success "Moved home data for '$username' to '$new_home'."
    else
        usermod -d "$new_home" "$username"
        success "Updated the home directory for '$username' to '$new_home'."
    fi

    pause
}

update_user_comment() {
    local username="$1"
    local new_comment

    new_comment="$(prompt_default "New full name/comment" "$(user_comment "$username")")"
    usermod -c "$new_comment" "$username"
    success "Updated the comment field for '$username'."
    pause
}

set_account_expiry() {
    local username="$1"
    local expiry_date

    expiry_date="$(prompt_required "Expiry date (YYYY-MM-DD): ")"
    chage -E "$expiry_date" "$username"
    success "Expiry date for '$username' set to '$expiry_date'."
    pause
}

clear_account_expiry() {
    chage -E -1 "$1"
    success "Cleared the expiry date for '$1'."
    pause
}

force_password_change() {
    chage -d 0 "$1"
    success "'$1' must change the password at next login."
    pause
}

show_group_details() {
    local group_name="$1"
    local group_line
    local resolved_name
    local gid
    local explicit_members
    local primary_members
    local all_members
    local role_label='regular group'

    if ! group_exists "$group_name"; then
        error "Group '$group_name' does not exist."
        pause
        return 1
    fi

    group_line="$(getent group "$group_name")"
    IFS=':' read -r resolved_name _ gid explicit_members <<< "$group_line"
    primary_members="$(group_primary_members_csv "$group_name")"
    all_members="$(group_all_members_csv "$group_name")"

    if [[ "$group_name" == 'wheel' ]]; then
        role_label='sudo/admin group'
    elif [[ "$group_name" == 'root' ]]; then
        role_label='root system group'
    fi

    print_banner
    printf '%sGroup profile: %s%s\n\n' "$C_BOLD" "$group_name" "$C_RESET"
    printf '  Group name     : %s\n' "$resolved_name"
    printf '  GID            : %s\n' "$gid"
    printf '  Direct members : %s\n' "${explicit_members:-<none>}"
    printf '  Primary users  : %s\n' "${primary_members:-<none>}"
    printf '  All members    : %s\n' "${all_members:-<none>}"
    printf '  Role           : %s\n' "$role_label"
    pause
}

rename_group_entry() {
    local group_name="$1"
    local new_group_name

    if is_protected_group "$group_name"; then
        warn "Refusing to rename the protected group '$group_name'."
        return 1
    fi

    while :; do
        new_group_name="$(prompt_required "New group name: ")"
        if ! validate_group_name "$new_group_name"; then
            warn "Invalid group name format."
            continue
        fi
        if group_exists "$new_group_name"; then
            warn "Group '$new_group_name' already exists."
            continue
        fi
        break
    done

    groupmod -n "$new_group_name" "$group_name"
    success "Renamed group '$group_name' to '$new_group_name'."
    printf '%s' "$new_group_name"
}

add_members_to_group() {
    local group_name="$1"
    local requested_users
    local username
    local user_array=()

    requested_users="$(normalize_csv "$(trim "$(read_input "Users to add to '$group_name' (comma-separated): ")")")"
    if [[ -z "$requested_users" ]]; then
        warn "No users were entered."
        pause
        return 1
    fi

    IFS=',' read -r -a user_array <<< "$requested_users"
    for username in "${user_array[@]}"; do
        username="$(trim "$username")"
        [[ -z "$username" ]] && continue

        if ! user_exists "$username"; then
            warn "Skipping '$username' because the user does not exist."
            continue
        fi

        if user_in_group "$username" "$group_name"; then
            warn "Skipping '$username' because the user is already in '$group_name'."
            continue
        fi

        usermod -aG "$group_name" "$username"
        success "Added '$username' to '$group_name'."
    done

    pause
}

remove_members_from_group() {
    local group_name="$1"
    local all_members
    local requested_users
    local username
    local user_array=()

    all_members="$(group_all_members_csv "$group_name")"

    print_banner
    printf '%sCurrent members of %s%s\n\n' "$C_BOLD" "$group_name" "$C_RESET"
    printf '  %s\n\n' "${all_members:-<none>}"

    requested_users="$(normalize_csv "$(trim "$(read_input "Users to remove (comma-separated): ")")")"
    if [[ -z "$requested_users" ]]; then
        warn "No users were entered."
        pause
        return 1
    fi

    IFS=',' read -r -a user_array <<< "$requested_users"
    for username in "${user_array[@]}"; do
        username="$(trim "$username")"
        [[ -z "$username" ]] && continue

        if ! user_exists "$username"; then
            warn "Skipping '$username' because the user does not exist."
            continue
        fi

        if [[ "$(id -gn "$username")" == "$group_name" ]]; then
            warn "Skipping '$username' because '$group_name' is the primary group."
            continue
        fi

        if ! user_in_group "$username" "$group_name"; then
            warn "Skipping '$username' because the user is not in '$group_name'."
            continue
        fi

        gpasswd -d "$username" "$group_name"
        success "Removed '$username' from '$group_name'."
    done

    pause
}

set_group_gid() {
    local group_name="$1"
    local new_gid

    if is_protected_group "$group_name"; then
        warn "Refusing to change the GID of the protected group '$group_name'."
        pause
        return 1
    fi

    while :; do
        new_gid="$(prompt_required "New numeric GID: ")"
        if [[ "$new_gid" =~ ^[0-9]+$ ]]; then
            break
        fi
        warn "GID must be numeric."
    done

    groupmod -g "$new_gid" "$group_name"
    success "Changed the GID for '$group_name' to '$new_gid'."
    pause
}

delete_group_entry() {
    local group_name="$1"
    local primary_members
    local confirmation

    if is_protected_group "$group_name"; then
        warn "Refusing to delete the protected group '$group_name'."
        pause
        return 1
    fi

    primary_members="$(group_primary_members_csv "$group_name")"
    if [[ -n "$primary_members" ]]; then
        warn "Cannot delete '$group_name' while it is the primary group for: $primary_members"
        pause
        return 1
    fi

    print_banner
    warn "You are about to delete group '$group_name'. This cannot be undone."

    confirmation="$(trim "$(read_input "Type the group name again to confirm: ")")"
    if [[ "$confirmation" != "$group_name" ]]; then
        warn "Confirmation did not match. Deletion cancelled."
        pause
        return 1
    fi

    groupdel "$group_name"
    success "Deleted group '$group_name'."
    pause
    return 0
}

manage_group_menu() {
    local group_name="$1"
    local choice
    local all_members
    local renamed_group

    while :; do
        all_members="$(group_all_members_csv "$group_name")"

        print_banner
        printf '%sManaging group: %s%s\n' "$C_BOLD" "$group_name" "$C_RESET"
        printf '%sAll members:%s %s\n\n' "$C_DIM" "$C_RESET" "${all_members:-<none>}"
        printf '  1. View group details\n'
        printf '  2. Rename group\n'
        printf '  3. Add users to this group\n'
        printf '  4. Remove users from this group\n'
        printf '  5. Change group GID\n'
        printf '  6. Switch to another group\n'
        printf '  7. Delete this group\n'
        printf '  8. Back to main menu\n\n'

        choice="$(trim "$(read_input "Choose an action: ")")"
        case "$choice" in
            1)
                show_group_details "$group_name"
                ;;
            2)
                if renamed_group="$(rename_group_entry "$group_name")"; then
                    group_name="$renamed_group"
                fi
                pause
                ;;
            3)
                add_members_to_group "$group_name"
                ;;
            4)
                remove_members_from_group "$group_name"
                ;;
            5)
                set_group_gid "$group_name"
                ;;
            6)
                group_name="$(select_existing_group)"
                ;;
            7)
                if delete_group_entry "$group_name"; then
                    return 0
                fi
                ;;
            8|q|Q|b|B)
                return 0
                ;;
            *)
                warn "Choose a number from the menu."
                pause
                ;;
        esac
    done
}

manage_user_menu() {
    local username="$1"
    local choice
    local renamed_user

    while :; do
        print_banner
        printf '%sManaging user: %s%s\n' "$C_BOLD" "$username" "$C_RESET"
        printf '%sCurrent groups:%s %s\n\n' "$C_DIM" "$C_RESET" "$(id -nG "$username")"
        printf '  1. View user details\n'
        printf '  2. Rename user\n'
        printf '  3. Set password\n'
        printf '  4. Lock account\n'
        printf '  5. Unlock account\n'
        printf '  6. Grant sudo access\n'
        printf '  7. Revoke sudo access\n'
        printf '  8. Add supplementary groups\n'
        printf '  9. Remove supplementary groups\n'
        printf ' 10. Change primary group\n'
        printf ' 11. Change login shell\n'
        printf ' 12. Move home directory\n'
        printf ' 13. Update full name/comment\n'
        printf ' 14. Set account expiry\n'
        printf ' 15. Clear account expiry\n'
        printf ' 16. Force password change on next login\n'
        printf ' 17. Delete this user\n'
        printf ' 18. Switch to another user\n'
        printf ' 19. Back to main menu\n\n'

        choice="$(trim "$(read_input "Choose an action: ")")"
        case "$choice" in
            1)
                show_user_details "$username"
                ;;
            2)
                renamed_user="$(rename_user_account "$username")"
                username="$renamed_user"
                pause
                ;;
            3)
                set_user_password "$username"
                ;;
            4)
                lock_user_account "$username"
                ;;
            5)
                unlock_user_account "$username"
                ;;
            6)
                grant_sudo_access "$username"
                ;;
            7)
                revoke_sudo_access "$username"
                ;;
            8)
                add_supplementary_groups "$username"
                ;;
            9)
                remove_supplementary_groups "$username"
                ;;
            10)
                change_primary_group "$username"
                ;;
            11)
                change_login_shell "$username"
                ;;
            12)
                move_home_directory "$username"
                ;;
            13)
                update_user_comment "$username"
                ;;
            14)
                set_account_expiry "$username"
                ;;
            15)
                clear_account_expiry "$username"
                ;;
            16)
                force_password_change "$username"
                ;;
            17)
                if delete_user_account "$username"; then
                    return 0
                fi
                ;;
            18)
                username="$(select_existing_user)"
                ;;
            19|q|Q|b|B)
                return 0
                ;;
            *)
                warn "Choose a number from the menu."
                pause
                ;;
        esac
    done
}

main_menu() {
    local choice

    while :; do
        print_banner
        printf '%sMain menu%s\n\n' "$C_BOLD" "$C_RESET"
        printf '%sUser actions%s\n' "$C_DIM" "$C_RESET"
        printf '  1. Create a user\n'
        printf '  2. Manage an existing user\n'
        printf '  3. View a user\n'
        printf '  4. Delete a user\n'
        printf '  5. List users\n\n'
        printf '%sGroup actions%s\n' "$C_DIM" "$C_RESET"
        printf '  6. Create a group\n'
        printf '  7. Manage an existing group\n'
        printf '  8. View a group\n'
        printf '  9. Delete a group\n'
        printf ' 10. List groups\n'
        printf ' 11. Help\n'
        printf ' 12. Exit\n\n'

        choice="$(trim "$(read_input "Choose an action: ")")"
        case "$choice" in
            1)
                create_user_interactive
                ;;
            2)
                manage_user_menu "$(select_existing_user)"
                ;;
            3)
                show_user_details "$(select_existing_user)"
                ;;
            4)
                delete_user_account "$(select_existing_user)" || true
                ;;
            5)
                list_users_screen
                pause
                ;;
            6)
                create_group_interactive
                ;;
            7)
                manage_group_menu "$(select_existing_group)"
                ;;
            8)
                show_group_details "$(select_existing_group)"
                ;;
            9)
                delete_group_entry "$(select_existing_group)" || true
                ;;
            10)
                list_groups_screen
                pause
                ;;
            11)
                print_banner
                print_usage
                pause
                ;;
            12|q|Q)
                exit 0
                ;;
            *)
                warn "Choose a number from the menu."
                pause
                ;;
        esac
    done
}

main() {
    case "${1:-}" in
        --help|-h)
            print_usage
            exit 0
            ;;
        --list|-l)
            list_users_table
            exit 0
            ;;
        --groups|-G)
            list_groups_table
            exit 0
            ;;
        --group|-g)
            if [[ -z "${2:-}" ]]; then
                error "Provide a group name after '$1'."
                printf '\n'
                print_usage >&2
                exit 1
            fi
            if ! group_exists "$2"; then
                error "Group '$2' does not exist."
                printf '\n'
                print_usage >&2
                exit 1
            fi
            ensure_commands
            require_root "$@"
            manage_group_menu "$2"
            ;;
        '')
            ensure_commands
            require_root "$@"
            main_menu
            ;;
        *)
            ensure_commands
            if user_exists "$1"; then
                require_root "$@"
                manage_user_menu "$1"
            elif group_exists "$1"; then
                require_root "$@"
                manage_group_menu "$1"
            else
                error "'$1' does not match an existing user or group."
                printf '\n'
                print_usage >&2
                exit 1
            fi
            ;;
    esac
}

main "$@"