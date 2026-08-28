#!/bin/sh
# install.sh: install the CLI and its macOS launchd user agent.
# launchd is required for its login-session credential environment: the GUI
# agent carries SSH_AUTH_SOCK and login-Keychain access needed by cluster probes.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=${REPO_DIR:-"$script_dir"}
PM_HOME=${PASEO_MONITOR_HOME:-"$HOME/.paseo-monitor"}
PM_LABEL=com.paseo-monitor.sweep
PM_PLIST="$HOME/Library/LaunchAgents/$PM_LABEL.plist"
PM_TEMPLATE="$REPO_DIR/launchd/$PM_LABEL.plist.in"
PM_SKILL_SOURCE="$REPO_DIR/skills/paseo-monitor/SKILL.md"

PM_SOURCE_ONLY=1
export PM_SOURCE_ONLY PASEO_MONITOR_HOME
# shellcheck disable=SC1090
. "$REPO_DIR/bin/paseo-monitor"

pm_install_lock() {
    ensure_dirs "$PM_HOME" || exit 1
    acquire_lock "$PM_HOME" || {
        echo "install.sh: monitor sweep lock is held" >&2
        exit 1
    }
    trap 'release_lock "$PM_HOME"' 0 1 2 3 15
}

pm_launchd_print() {
    launchctl print "gui/$(id -u)/$PM_LABEL" >/dev/null 2>&1
}

pm_install_skills() {
    [ -f "$PM_SKILL_SOURCE" ] || {
        echo "install.sh: skill source missing: $PM_SKILL_SOURCE" >&2
        exit 1
    }
    for pis_root in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
        mkdir -p "$pis_root/paseo-monitor"
        if ! cmp -s "$PM_SKILL_SOURCE" "$pis_root/paseo-monitor/SKILL.md" 2>/dev/null; then
            cp "$PM_SKILL_SOURCE" "$pis_root/paseo-monitor/SKILL.md"
        fi
    done
}

pm_install_agent() {
    [ "$(id -u)" != 0 ] || {
        echo "install.sh: refusing to run as root" >&2
        exit 1
    }
    command -v launchctl >/dev/null 2>&1 || {
        echo "install.sh: launchctl is required on macOS" >&2
        exit 1
    }
    [ -f "$PM_TEMPLATE" ] || {
        echo "install.sh: plist template missing: $PM_TEMPLATE" >&2
        exit 1
    }
    pm_install_lock
    chmod +x "$REPO_DIR/bin/paseo-monitor"
    mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
    ln -sf "$REPO_DIR/bin/paseo-monitor" "$HOME/.local/bin/paseo-monitor"
    pm_install_skills
    if [ -f "$PM_PLIST" ] && ! grep -q 'paseo-monitor: managed launchd agent' "$PM_PLIST"; then
        echo "install.sh: refusing to replace unmanaged plist: $PM_PLIST" >&2
        exit 1
    fi
    pm_path="$(printf '%s' "${PATH:-}" | sed 's/[\\&|]/\\&/g')"
    pm_content="$(sed -e "s|__PASEO_MONITOR_BIN__|$REPO_DIR/bin/paseo-monitor|g" \
        -e "s|__PASEO_MONITOR_REPO__|$REPO_DIR|g" \
        -e "s|__PASEO_MONITOR_HOME__|$PM_HOME|g" \
        -e "s|__PASEO_MONITOR_PATH__|$pm_path|g" "$PM_TEMPLATE")"
    pm_atomic_write "$PM_PLIST" "$pm_content"
    chmod 600 "$PM_PLIST"
    if pm_launchd_print; then
        launchctl bootout "gui/$(id -u)/$PM_LABEL" >/dev/null 2>&1 || :
    fi
    if ! launchctl bootstrap "gui/$(id -u)" "$PM_PLIST" >/dev/null 2>&1; then
        pm_launchd_print || {
            echo "install.sh: launchctl bootstrap failed" >&2
            exit 1
        }
    fi
    if ! command -v paseo-monitor >/dev/null 2>&1 || ! paseo-monitor --help >/dev/null 2>&1; then
        echo "install.sh: FAILED - paseo-monitor is not on PATH or --help failed." >&2
        exit 1
    fi
    echo "install.sh: SUCCESS - installed $HOME/.local/bin/paseo-monitor -> $REPO_DIR/bin/paseo-monitor"
    echo "install.sh: SUCCESS - launchd agent $PM_LABEL bootstrapped"
}

pm_uninstall_agent() {
    [ "$(id -u)" != 0 ] || {
        echo "install.sh: refusing to run as root" >&2
        exit 1
    }
    command -v launchctl >/dev/null 2>&1 || {
        echo "install.sh: launchctl is required on macOS" >&2
        exit 1
    }
    pm_install_lock
    if pm_launchd_print; then
        launchctl bootout "gui/$(id -u)/$PM_LABEL" >/dev/null 2>&1 || {
            pm_launchd_print && {
                echo "install.sh: launchctl bootout failed" >&2
                exit 1
            }
        }
    fi
    rm -f "$PM_PLIST" "$HOME/.local/bin/paseo-monitor"
    echo "install.sh: SUCCESS - launchd agent $PM_LABEL uninstalled"
}

case "${1:-install}" in
    install) pm_install_agent ;;
    uninstall|remove) pm_uninstall_agent ;;
    *) echo "Usage: install.sh [install|uninstall]" >&2; exit 2 ;;
esac
