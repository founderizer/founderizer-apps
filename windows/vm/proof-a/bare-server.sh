#!/bin/bash
# bare-server.sh: the server of proof A's run 2 ("Other VPS", "1 server"): one bare Ubuntu 24.04 server at Hetzner, in
# the test project of the hcloud context founderizer-test (never the context that is active), with no SSH key, the
# label temporary=true, and root's password from a hash that cloud-init sets, as a person gets a VPS with a password.
#
#   bare-server.sh make [--name proof-a-vps] [--types cx23,cpx22] [--location hel1]
#   bare-server.sh delete <name>     deletes it, only when it has the labels temporary=true and proof=a
#   bare-server.sh list              the servers of the test project with the label proof=a
#   bare-server.sh --print-only      the cloud-init text (with <hash> for the hash) and the create command; changes nothing
#
# make: the owner types a new password at a prompt that does not show it, two times (16 or more letters, digits and
# "-"). Only its SHA-512 crypt hash leaves this Mac, on hcloud's standard input (no file, no argument). The password
# that Hetzner makes for a server with no key is not printed: cloud-init replaces it. When SSH offers password sign-in,
# the script prints the server's address (not a secret: the session types it on the VPS page) and waits, with the
# password in its memory only, until the session puts the focus on the password field of the copy that
# FZ_PROOF_A_COPY names; then it types the password there with secret.sh (its checks, its log of the field's name).
# The server costs money by the hour until delete: the owner's yes comes first.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
umask 077

context="founderizer-test"
hcloud_test() { hcloud --context "$context" "$@"; }
name="proof-a-vps"
types="cx23,cpx22"
location="hel1"
image="ubuntu-24.04"

# The text of cloud-init, for a hash: root signs in with that password over SSH (and with nothing else that this
# script gives), and it is not marked as expired. printf, not a here-document: bash 3.2 writes a here-document to a
# file for a moment, and no file may hold the hash.
user_data() {
    printf '%s\n' '#cloud-config' 'ssh_pwauth: true' 'disable_root: false' 'chpasswd:' '  expire: false' '  users:' \
        '    - name: root' "      password: '$1'" '      type: hash' 'write_files:' \
        '  - path: /etc/ssh/sshd_config.d/00-proof-a.conf' "    permissions: '0644'" '    content: |' \
        '      PermitRootLogin yes' '      PasswordAuthentication yes' 'runcmd:' "  - [usermod, -p, '$1', root]" \
        '  - [systemctl, reload, ssh]'
}

# Whether the test project has a server of this name: "yes"; "no" only when Hetzner says that it is not found; and
# "unknown" for every other answer (a fault of the network, of the token), in which a server can exist and cost.
server_there() {
    local said
    if said="$(hcloud_test server describe "$1" -o json 2>&1 >/dev/null)"; then echo yes
    # hcloud's own words for a name that the project does not have ("hcloud: Server not found: <name>"); not a proxy's
    # "404 Not Found" or a shell's "command not found"
    elif printf '%s' "$said" | grep -q 'Server not found: '; then echo no
    else echo unknown; fi
}

find_openssl() {
    local candidate probe
    for candidate in /opt/homebrew/bin/openssl /usr/local/bin/openssl "$(command -v openssl 2>/dev/null)"; do
        [ -x "$candidate" ] || continue
        probe="$(printf 'probe\n' | "$candidate" passwd -6 -stdin 2>/dev/null)"
        case "$probe" in '$6$'*) printf '%s' "$candidate"; return 0 ;; esac
    done
    return 1
}

create_command() {
    printf 'hcloud --context %s server create --name %s --type <%s> --image %s --location %s --label temporary=true --label proof=a --user-data-from-file - -o json\n' \
        "$context" "$name" "${types//,/ or }" "$image" "$location"
}

command="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --name) name="$2"; shift 2 ;;
        --types) types="$2"; shift 2 ;;
        --location) location="$2"; shift 2 ;;
        *) [ -z "${target:-}" ] && target="$1" && shift && continue; proof_die "unknown option $1" ;;
    esac
done
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || proof_die "a server's name has small letters, digits and \"-\": $name"

case "$command" in
--print-only)
    user_data '<hash>'
    create_command
    ;;
list)
    hcloud_test server list --selector proof=a -o columns=id,name,status,ipv4,type,location,labels,created
    ;;
delete)
    [ -n "${target:-}" ] || proof_die "delete needs the server's name"
    case "$(server_there "$target")" in
        no) proof_die "Hetzner says that the test project has no server $target: nothing to delete" ;;
        unknown) proof_die "Hetzner did not say whether a server $target exists: it can still cost. Run bare-server.sh delete $target again" ;;
    esac
    labels="$(hcloud_test server describe "$target" -o json | python3 -I -c 'import json,sys; l=json.load(sys.stdin)["labels"]; print(l.get("temporary",""), l.get("proof",""))')" ||
        proof_die "Hetzner did not give the labels of $target: it can still cost. Run bare-server.sh delete $target again"
    [ "$labels" = "true a" ] || proof_die "the server $target is not a temporary server of proof A; nothing was deleted"
    hcloud_test server delete "$target"
    ;;
make)
    [ -n "${FZ_PROOF_A_COPY:-}" ] || proof_die "name the copy whose password field gets the password: FZ_PROOF_A_COPY=<copy>"
    use_copy
    hcloud context list 2>/dev/null | awk '{print $NF}' | grep -qx "$context" || proof_die "no hcloud context $context on this Mac"
    openssl_bin="$(find_openssl)" || proof_die "no openssl here makes a SHA-512 crypt hash (openssl passwd -6): install OpenSSL 3"
    case "$(server_there "$name")" in
        yes) proof_die "a server $name exists in the test project already" ;;
        unknown) proof_die "Hetzner did not say whether a server $name exists; nothing was made" ;;
    esac
    printf 'New test server password (16 or more letters, digits and "-"; it does not show): '
    IFS= read -r -s password; echo
    printf 'Type it again: '
    IFS= read -r -s again; echo
    if [ "$password" != "$again" ]; then unset password again; proof_die "the two were not the same; nothing was made"; fi
    unset again
    if ! [[ "$password" =~ ^[A-Za-z0-9-]{16,}$ ]]; then unset password; proof_die "16 or more letters, digits and \"-\" only; nothing was made"; fi
    hash="$(printf '%s\n' "$password" | "$openssl_bin" passwd -6 -stdin)"
    case "$hash" in '$6$'*) ;; *) unset password hash; proof_die "the hash was not made; nothing was made" ;; esac
    made=""
    # From the first request on, a server can exist: a stop by Ctrl-C says how it goes.
    trap 'unset password hash; proof_say "stopped. If a server $name exists in the test project, it costs until: bare-server.sh delete $name"; exit 130' INT
    for type in ${types//,/ }; do
        proof_say "making $name ($type, $location, $image) in the test project"
        # The answer of the API holds the password that Hetzner made: only the id, the name and the address are kept,
        # and no line of hcloud's own that names a password is shown.
        if made="$(user_data "$hash" | hcloud_test server create --name "$name" --type "$type" --image "$image" \
                --location "$location" --label temporary=true --label proof=a --user-data-from-file - -o json \
                2> >(grep -v -i password >&2) |
                python3 -I -c 'import json,sys; s=json.load(sys.stdin)["server"]; print(s["id"], s["name"], s["public_net"]["ipv4"]["ip"])' 2>/dev/null)" &&
            [ -n "$made" ]; then
            break
        fi
        made=""
        # Hetzner can make the server and its answer still not be read: then the name is taken, and no other type is
        # tried.
        [ "$(server_there "$name")" = no ] || break
        proof_say "Hetzner did not make a $type server now"
    done
    unset hash
    if [ -z "$made" ]; then
        unset password
        case "$(server_there "$name")" in
            yes) proof_die "the server $name exists, but its answer was not read. It costs by the hour until: bare-server.sh delete $name" ;;
            no) proof_die "no server was made; nothing costs" ;;
            *) proof_die "Hetzner did not say whether the server $name exists. If it does, it costs by the hour until: bare-server.sh delete $name" ;;
        esac
    fi
    read -r id made_name address <<<"$made"
    proof_say "made $made_name (id $id); it costs by the hour until: bare-server.sh delete $made_name"
    # Password sign-in is on when SSH offers it: asked with no password and no key, the server lists its ways.
    for _ in $(seq 1 60); do
        ways="$(ssh -n -F /dev/null -o BatchMode=yes -o PreferredAuthentications=none -o PubkeyAuthentication=no \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
            "root@$address" true 2>&1 | sed -n 's/.*Permission denied (\(.*\)).*/\1/p')"
        case ",$ways," in *,password,*) break ;; esac
        sleep 10
    done
    case ",$ways," in *,password,*) ;; *) unset password; proof_die "after 10 minutes SSH on $address does not offer password sign-in (it offers: ${ways:-nothing}). Delete it: bare-server.sh delete $made_name" ;; esac
    echo "The server is ready: $address (port 22, user root). Tell the session this address."
    echo "Keep this window open. The password goes into the test computer when the session puts the focus on its field."
    for _ in $(seq 1 720); do
        line="$("$vm_sh" desktop '& C:\fz\proof-a\focus.ps1' 2>/dev/null | tr -d '\r' | grep '^focus' | tail -1)"
        case "$line" in *$'\t'id=first-run-vps-password$'\t'*)
            printf '%s\n%s\n' "$password" "$password" |
                "$proof_here/secret.sh" "New test server password" --field first-run-vps-password --twice --no-enter
            code=$?
            unset password
            exit "$code" ;;
        esac
        sleep 5
    done
    unset password
    proof_die "the password field had no focus in one hour; the password was not typed. The server stays until: bare-server.sh delete $made_name"
    ;;
*)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
