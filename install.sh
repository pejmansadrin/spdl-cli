#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Project Configuration ---
INSTALL_DIR="$HOME/spdl-cli"
VENV_DIR="venv"

# --- Helper Functions ---
echo_green() { echo -e "${GREEN}$1${NC}"; }
echo_yellow() { echo -e "${YELLOW}$1${NC}"; }
echo_red() { echo -e "${RED}$1${NC}"; }

read_masked() {
    local prompt="$1"
    local secret_var_name="$2"
    local secret=""
    local char
    echo -n "$prompt"
    stty -echo
    while IFS= read -r -n1 char; do
        if [[ -z "$char" ]]; then break; fi
        if [[ "$char" == $'\x7f' ]]; then
            if [ -n "$secret" ]; then
                secret="${secret%?}"; echo -ne "\b \b";
            fi
        else
            secret+="$char"; echo -n "*";
        fi
    done
    stty echo
    eval "$secret_var_name=\"$secret\""
    echo
}

# --- Smart Installer Functions ---

detect_os() {
    echo "--> Detecting Operating System..."
    if [[ "$(uname)" == "Darwin" ]]; then OS="macos";
    elif [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID;
    else OS="unknown"; fi
    echo "OS detected: $OS"
}

install_system_deps() {
    echo_green "\n---> Step 1: Installing System Dependencies..."
    if ! sudo -v &> /dev/null; then
        echo_red "Error: sudo privileges are required."; exit 1;
    fi
    case $OS in
        "macos")
            if ! command -v brew &> /dev/null; then echo_red "Homebrew not found. Please install it first from https://brew.sh"; exit 1; fi
            echo "Using Homebrew..."; brew install python ffmpeg
            ;;
        "fedora"|"rhel"|"centos")
            echo "Using DNF...";
            sudo dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
            sudo dnf install -y python3 python3-pip ffmpeg
            ;;
        "ubuntu"|"debian")
            echo "Using APT..."; sudo apt-get update; sudo apt-get install -y python3 python3-pip ffmpeg
            ;;
        "cachyos"|"arch")
            echo "Using Pacman..."; sudo pacman -Syu --noconfirm --needed python python-pip ffmpeg
            ;;
        *)
            echo_red "Unsupported OS: $OS."; echo_yellow "Please manually install: python3, pip, and ffmpeg."
            read -p "Press [Enter] to continue, or Ctrl+C to exit."
            ;;
    esac
    echo_green "System dependencies are ready."
}

prompt_keys() {
    echo_yellow "\nPlease enter your Spotify API credentials."
    read -p "Enter your Spotify CLIENT_ID: " spotify_client_id </dev/tty
    read_masked "Enter your Spotify CLIENT_SECRET: " spotify_client_secret
    if [[ -z "$spotify_client_id" || -z "$spotify_client_secret" ]]; then
        echo_red "Error: Both keys must be provided."; exit 1;
    fi
}

setup_project() {
    echo_green "\n---> Step 2: Setting up project directory and Python environment..."
    mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"
    echo "Project directory: $(pwd)"
    echo "Creating Python virtual environment..."; python3 -m venv "$VENV_DIR"
    echo "Creating requirements.txt..."
    cat << EOF > requirements.txt
spotipy
yt-dlp
mutagen
requests
rich
EOF
    echo "Installing Python packages..."; "$VENV_DIR/bin/pip" install -r requirements.txt
    echo_green "Python environment is ready."
}

create_spdl_script() {
    echo_green "\n---> Step 3: Creating the main spdl.py script..."
    cat << EOF > spdl.py
#!${INSTALL_DIR}/${VENV_DIR}/bin/python3
import os, sys, spotipy, yt_dlp, requests
from spotipy.oauth2 import SpotifyClientCredentials
from spotipy.exceptions import SpotifyException
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, APIC, TIT2, TPE1, TALB, TRCK, TPOS, TDRC
from rich.console import Console
from rich.progress import Progress, BarColumn, TextColumn, TimeRemainingColumn, TransferSpeedColumn

# --- Configuration ---
console = Console()
CLIENT_ID = 'YOUR_CLIENT_ID'
CLIENT_SECRET = 'YOUR_CLIENT_SECRET'
DOWNLOAD_DIR = 'Spotify Downloads'

def download_track(track_object):
    all_artists = ', '.join(artist['name'] for artist in track_object['artists'])
    track_name = track_object['name']
    console.print(f"🎵 Attempting to download: [bold cyan]{track_name}[/] by [bold cyan]{all_artists}[/]")
    safe_filename = "".join(c for c in f"{all_artists} - {track_name}" if c.isalnum() or c in (' ', '.', '_')).rstrip()
    final_mp3_path = os.path.join(DOWNLOAD_DIR, f"{safe_filename}.mp3")
    if os.path.exists(final_mp3_path):
        console.print(f"🟡 [yellow]'{track_name}' already exists. Skipping...[/]"); return
    search_query = f"{all_artists} - {track_name} audio"
    with Progress(TextColumn("[bold blue]{task.fields[filename]}", justify="right"), BarColumn(bar_width=None),"[progress.percentage]{task.percentage:>3.1f}%", "•", TransferSpeedColumn(), "•", TimeRemainingColumn(),console=console) as progress:
        download_task = progress.add_task("download", filename=f"{safe_filename}.mp3", total=None)
        def progress_hook(d):
            if d['status'] == 'downloading':
                total_bytes = d.get('total_bytes') or d.get('total_bytes_estimate')
                if total_bytes is not None: progress.update(download_task, total=total_bytes, completed=d['downloaded_bytes'])
            elif d['status'] == 'finished':
                progress.update(download_task, description="[bold green]Processing...")
        ydl_opts = {'format': 'bestaudio/best', 'postprocessors': [{'key': 'FFmpegExtractAudio', 'preferredcodec': 'mp3', 'preferredquality': '192'}],'outtmpl': os.path.join(DOWNLOAD_DIR, safe_filename), 'quiet': True, 'progress_hooks': [progress_hook], 'default_search': 'ytsearch1',}
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl: ydl.download([search_query])
            if not os.path.exists(final_mp3_path): raise FileNotFoundError(f"Download failed, file not found at {final_mp3_path}")
            console.print("    🎨 [italic]Applying extended metadata...[/]")
            album_name = track_object['album']['name']; image_url = track_object['album']['images'][0]['url']; track_number = str(track_object['track_number']); disc_number = str(track_object['disc_number']); release_date = track_object['album']['release_date']; image_data = requests.get(image_url).content
            audio = MP3(final_mp3_path, ID3=ID3)
            audio.tags.add(APIC(encoding=3, mime='image/jpeg', type=3, desc='Cover', data=image_data))
            audio.tags.add(TIT2(encoding=3, text=track_name)); audio.tags.add(TALB(encoding=3, text=album_name)); audio.tags.add(TPE1(encoding=3, text=all_artists)); audio.tags.add(TRCK(encoding=3, text=track_number)); audio.tags.add(TPOS(encoding=3, text=disc_number)); audio.tags.add(TDRC(encoding=3, text=release_date))
            audio.save(v2_version=3)
            console.print(f"✅ [bold green]Success![/] '{track_name}' is ready.")
        except Exception as e: console.print(f"❌ [bold red]Error processing '{track_name}':[/] {e}")

def print_help_and_exit():
    print("Usage: spdl [URL]")
    sys.exit(0)

def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("--help", "-h"):
        print_help_and_exit()

    track_url = sys.argv[1]

    # Initialization
    try:
        if not os.path.exists(DOWNLOAD_DIR): os.makedirs(DOWNLOAD_DIR)
        auth_manager = SpotifyClientCredentials(client_id=CLIENT_ID, client_secret=CLIENT_SECRET)
        sp = spotipy.Spotify(auth_manager=auth_manager)
    except Exception as e:
        console.print(f"❌ [bold red]Initialization Failed:[/] {e}"); sys.exit(1)

    # Validation and Execution
    if "spotify.com/track" not in track_url:
        console.print("❌ [bold red]Invalid Input:[/] Please provide a valid Spotify track URL."); sys.exit(1)
    try:
        track_data = sp.track(track_url)
        if track_data:
            download_track(track_data)
            console.print("\n✨ [bold]All tasks complete![/]")
        else:
            console.print("❌ [bold red]Could not retrieve track data. Please check the URL.[/]")
    except SpotifyException:
        console.print(f"❌ [bold red]Spotify API Error:[/] Could not get track info."); sys.exit(1)
    except Exception as e:
        console.print(f"❌ [bold red]An unexpected error occurred:[/] {e}"); sys.exit(1)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n\n🔴 [bold]Operation cancelled by user.[/]")
        sys.exit(130)
EOF
    sed -i "s|YOUR_CLIENT_ID|$spotify_client_id|" spdl.py
    sed -i "s|YOUR_CLIENT_SECRET|$spotify_client_secret|" spdl.py
    echo_green "spdl.py script created successfully."
}

finalize_setup() {
    echo_green "\n---> Step 4: Making the 'spdl' command available system-wide..."
    chmod +x spdl.py
    echo "Creating symbolic link in /usr/local/bin..."
    sudo ln -sf "$INSTALL_DIR/spdl.py" /usr/local/bin/spdl
    echo_green "'spdl' command is now ready to use!"
}

# --- Main Execution ---
main() {
    echo_green "====================================="
    echo_green "   spdl - Universal Setup Script   "
    echo_green "====================================="
    detect_os
    install_system_deps
    prompt_keys
    setup_project
    create_spdl_script
    finalize_setup
    echo_green "\n🎉 Installation Complete! 🎉"
    echo_yellow "You can now run the downloader from anywhere in your terminal."
    echo "Example usage:"
    echo_yellow "spdl https://open.spotify.com/track/your-track-id"
    echo -e "Your downloaded files will be in: ${YELLOW}$INSTALL_DIR/Spotify Downloads${NC}"
}

main "$@"