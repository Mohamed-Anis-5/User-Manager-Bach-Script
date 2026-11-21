# User Manager Bash Script

A comprehensive, interactive Bash script for managing Linux system users and groups directly from the terminal. Designed to simplify routine system administration tasks without having to memorize complex flags for `useradd`, `usermod`, `userdel`, and `groupmod`.

## Features

*(Adjust this list to match the exact options in your script)*

* **User Management:** Create, modify, lock/unlock, and delete user accounts.
* **Group Management:** Create groups, delete groups, and add or remove users from supplementary groups.
* **Password & Security Controls:** Set or expire passwords and manage account aging policies.
* **User Inspection:** View detailed account information, active sessions, and group memberships.
* **Interactive CLI Menu:** Easy-to-navigate terminal interface with input validation and error handling.

## Prerequisites

* A Linux distribution (tested on **Fedora**; compatible with most modern Linux distros)
* **Bash** (`4.0+` recommended)
* **Root / `sudo` privileges** (required for creating, modifying, or deleting system accounts)

## Installation

### 1. Clone the Repository

```bash
git clone https://github.com/Mohamed-Anis-5/User-Manager-Bach-Script.git
cd User-Manager-Bach-Script
```

### 2. Make the Script Executable

```bash
chmod +x user_manager.sh
```

### 3. (Optional) Run from Anywhere

To launch the script from any directory just by typing `user`, copy it to your local `bin` folder:

```bash
mkdir -p ~/.local/bin
cp user_manager.sh ~/.local/bin/user
```

*(Make sure `~/.local/bin` is included in your `$PATH` environment variable.)*

## Usage

Run the script directly from the repository folder:

```bash
./user_manager.sh
```

Or, if you installed it to `~/.local/bin/user`, simply run:

```bash
user
```

Follow the on-screen menu prompts to perform user and group management tasks.

## Project Structure

```text
.
├── README.md
└── user_manager.sh
```

## Contributing

Contributions, bug reports, and feature suggestions are welcome! Feel free to open an issue or submit a pull request.

## License

This project is open source and available under the [MIT License](LICENSE).
