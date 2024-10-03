#!/usr/bin/env bash

#########################################################################
#                               TapeShift                               #
#########################################################################

# About:     Script for digitising VHS tapes using a USB capture device
# Device:    1D19:6108 Dexatek Technology Ltd USB Video Grabber
# Author:    Rohan Barar <rohan.barar@gmail.com>
# Date:      03 October 2024
#########################################################################

# Exit Status Codes:
# -----------------------------------------------------------------------
# 0  --> Success.
# 1  --> Missing Dependencies.
# 2  --> Nonexistent Video Input Device.
# 3  --> Nonexistent Audio Input Device.
# 4  --> Invalid Audio Bitrate.
# 5  --> Invalid CRF.
# 6  --> Invalid H.264 Preset.
# 7  --> Nonexistent Home Folder.
# 8  --> Invalid Output Directory.
# 9  --> Output Directory Creation Failure.
# 10 --> Output Directory Unwritable.
# 11 --> Invalid Output File Name.
# 12 --> Requested Output Path Contains Existing File.
# 13 --> Unsupported Detected Video Standard.
# 14 --> Operation Cancelled By User.
# 15 --> FFMPEG/FFPLAY Command Failure.
# 16 --> Capture Finalisation Failure.
# 17 --> Capture Trimming Failure.
# -----------------------------------------------------------------------

# TRAP SIGNALS
trap exit_script SIGINT SIGTERM EXIT

# GLOBAL CONSTANTS
# ANSI Escape Sequences
ANSI_BLUE="\033[1;34m"            # Bold Blue Text.
ANSI_CLEAR="\033[0m"              # Reset Text Formatting.
ANSI_GREEN="\033[1;32m"           # Bold Green Text.
ANSI_GREY="\e[38;5;250m"          # Grey Text.
ANSI_RED="\033[1;31m"             # Bold Red Text.
ANSI_YELLOW="\033[1;38;5;214m"    # Bold Yellow Text.
readonly ANSI_BLUE
readonly ANSI_CLEAR
readonly ANSI_GREEN
readonly ANSI_GREY
readonly ANSI_RED
readonly ANSI_YELLOW

# User Input Default Values
default_audio_bitrate="192"                                   # Capture audio bitrate in kbps.
default_crf="21"                                              # Constant Rate Factor (CRF).
default_preset="fast"                                         # H265 encoding preset.
default_output_directory="."                                  # Output the capture in the working directory.
default_output_file_name="VHS_$(date +"%Y%m%d_%H%M%S").ts"    # Example: 'VHS_20240927_220756.ts'.
readonly default_audio_bitrate
readonly default_crf
readonly default_preset
readonly default_output_directory
readonly default_output_file_name

# Other
h265_presets=("ultrafast" "superfast" "veryfast" "faster" "fast" "medium" "slow" "slower" "veryslow" "placebo")
illegal_chars='[<>:"|?*]'     # Characters not permitted in directory names and paths.
named_pipe="/tmp/vhs_pipe"    # Path to named pipe used to facilitate live preview during capture.
readonly h265_presets
readonly illegal_chars
readonly named_pipe

# GLOBAL VARIABLES
# Defaults (Dynamic)
default_video_device="/dev/video2"    # Video capture/input device.
default_audio_device="hw:1,0"         # Audio capture/input device.

# User Inputs
video_device=""        # Example: '/dev/video2'.
audio_device=""        # Example: 'hw:1,0'.
audio_bitrate=""       # Example: '128'.
crf=""                 # Example: '18'.
preset=""              # Example: 'fast'.
output_directory=""    # Example: '~/Videos/My\ VHS\ Captures'.
output_file_name=""    # Example: 'My\ Parents\ Wedding\ Ceremony'.

# Other
output_path=""           # Example: '~/Videos/My\ VHS\ Captures/My\ Parents\ Wedding\ Ceremony.ts'.
video_input_info=""      # Output of 'ffprobe' to determine characteristics of input video stream.
video_input_width=""     # Example: '720'.
video_input_height=""    # Example: '576'.
video_resolution=""      # Example: '576x720'.
frame_rate=""            # Example: '25'.
video_standard=""        # Example: 'PAL'.
ffmpeg_command=()        # Used to construct the FFMPEG command.
ffmpeg_pid=""            # Set by '$!' at runtime.
ffplay_pid=""            # Set by '$!' at runtime.
ff_error_flag=1          # Used to detect unexpected termination of FFMPEG.

# FUNCTIONS
# Function to ensure a clean exit on SIGINT & SIGTERM.
function exit_script() {
    if ps -p "$ffmpeg_pid" &>/dev/null || ps -p "$ffplay_pid" &>/dev/null; then
        # Only provide feedback if FFMPEG has not terminated already.
        if [ "$ff_error_flag" -eq 1 ]; then
            # Notify user that the request to halt the script was received.
            echo -e "\n${ANSI_YELLOW}[INFO]${ANSI_CLEAR} Stopping capture..."
        fi

        # Request FFMPEG and FFPLAY exit gracefully via SIGINT (Ctrl + C).
        kill -SIGINT "$ffmpeg_pid" &>/dev/null
        kill -SIGINT "$ffplay_pid" &>/dev/null

        # Wait for FFMPEG and FFPLAY to terminate.
        wait "$ffmpeg_pid" &>/dev/null
        wait "$ffplay_pid" &>/dev/null

        # Only provide feedback if FFMPEG has not terminated already.
        if [ "$ff_error_flag" -eq 1 ]; then
            # Notify user that the capture has stopped.
            echo -e "${ANSI_GREEN}[DONE]${ANSI_CLEAR} Capture stopped!"
        fi
    fi

    # Remove the named pipe if it exists.
    rm -f "$named_pipe"

    # Unset flag.
    ff_error_flag=0
}

function print_title() {
    # Width: 46 characters.
    # Height: 8 characters.
    local BOLD_ITALIC_TEXT="\e[1m\e[3m"

    # Print script name.
    # ASCII Art: 'Calligraphy' by Evangelos "GeopJr" Paterakis (Theme: 'Big')
    # https://flathub.org/apps/dev.geopjr.Calligraphy
    cat << "EOF"
 _______                _____ _     _  __ _   
|__   __|              / ____| |   (_)/ _| |  
   | | __ _ _ __   ___| (___ | |__  _| |_| |_ 
   | |/ _` | '_ \ / _ \\___ \| '_ \| |  _| __|
   | | (_| | |_) |  __/____) | | | | | | | |_ 
   |_|\__,_| .__/ \___|_____/|_| |_|_|_|  \__|
           | |                                
           |_|                                
EOF

    # Print version and author information.
    echo -e "${BOLD_ITALIC_TEXT}\
       v1.0.0 (03102024) by Rohan Barar       \
${ANSI_CLEAR}\n"
}

# Function to check if all required dependencies are available.
function check_dependencies() {
    local dependency
    for dependency in ffmpeg arecord v4l2-ctl; do
        if ! command -v "$dependency" &>/dev/null; then
            echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} '${dependency}' not installed!"
            exit 1
        fi
    done
}

# Function to create the named pipe.
function create_named_pipe() {
    if [[ ! -p "$named_pipe" ]]; then
        mkfifo "$named_pipe"
    fi
}

# Function to display available audio and video input devices.
function display_input_devices() {
    echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} Finding Video Devices..."
    echo "----------------------------------------------------------------"
    echo -e -n "${ANSI_GREY}"
    v4l2-ctl --list-devices
    echo -e -n "${ANSI_CLEAR}"
    echo "----------------------------------------------------------------"
    echo ""

    echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} Finding Audio Devices..."
    echo "----------------------------------------------------------------"
    echo -e -n "${ANSI_GREY}"
    arecord --list-devices
    echo -e -n "${ANSI_CLEAR}"
    echo "----------------------------------------------------------------"
    echo ""

    echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} To specify an audio input device:"
    echo "    1. Note the 'card' (e.g. 'X') and 'device' (e.g. 'Y') numbers corresponding to the desired input device."
    echo "    2. Specify the desired input device using 'hw:X,Y' syntax (e.g., hw:1,0)."
    echo ""
}

# Function to set default video and audio devices.
function set_default_input_devices() {
    local default_vid
    local default_aud
    default_vid=$(v4l2-ctl --list-devices | grep "^\s*/dev/video[0-9]*" | head -n 1 | xargs)
    default_aud=$(arecord --list-devices | grep "^card [0-9]*:.*, device [0-9]*:.*$" | head -n 1 | sed -n 's/card \([0-9]*\):.*device \([0-9]*\):.*/hw:\1,\2/p')

    if [ -n "$default_vid" ]; then
        default_video_device="$default_vid"
    fi

    if [ -n "$default_aud" ]; then
        default_audio_device="$default_aud"
    fi
}

# Function to request user-specified settings for the capture.
function capture_user_input() {
    # Set default video and audio devices.
    set_default_input_devices

    # Request user input.
    read -r -p "Enter the video input device (default: ${default_video_device}): " video_device
    read -r -p "Enter the audio device address (default: ${default_audio_device}): " audio_device
    read -r -p "Enter the audio bitrate in kbps (default: ${default_audio_bitrate}): " audio_bitrate
    read -r -p "Enter the Constant Rate Factor (CRF) value (default: ${default_crf}) [recommended: 20-23]: " crf
    read -r -p "Enter the desired H.264 preset (default: ${default_preset}): " preset # "medium" provides a good balance between speed, quality and compression efficiency.
    read -r -p "Enter the output directory (default: ${default_output_directory}): " output_directory
    read -r -p "Enter the output file name (default: ${default_output_file_name}): " output_file_name
    echo ""
}

# Function to check if user input is valid.
function check_user_input() {
    # Trim whitespace from user input.
    video_device=$(echo "$video_device" | xargs)
    audio_device=$(echo "$audio_device" | xargs)
    audio_bitrate=$(echo "$audio_bitrate" | xargs)
    crf=$(echo "$crf" | xargs)
    preset=$(echo "$preset" | xargs)
    output_directory=$(echo "$output_directory" | xargs)
    output_file_name=$(echo "$output_file_name" | xargs)

    # Substitute default values when user inputs are empty.
    video_device=${video_device:-$default_video_device}
    audio_device=${audio_device:-$default_audio_device}
    audio_bitrate=${audio_bitrate:-$default_audio_bitrate}
    crf=${crf:-$default_crf}
    preset=${preset:-$default_preset}
    output_directory=${output_directory:-$default_output_directory}
    output_file_name=${output_file_name:-$default_output_file_name}

    # Validate requested video input device.
    if [ ! -e "$video_device" ]; then
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} The video input device '${video_device}' does not exist!"
        exit 2
    fi

    # Validate requested audio input device.
    local audio_device_card   # Stores 'X' in 'hw:X,Y'.
    local audio_device_device # Stores 'Y' in 'hw:X,Y'.
    audio_device_card=$(echo "$audio_device" | cut -d':' -f2 | cut -d',' -f1)
    audio_device_device=$(echo "$audio_device" | cut -d',' -f2)

    if ! arecord --list-devices | grep -P "card $audio_device_card:.*,\s*device $audio_device_device:" &>/dev/null; then
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} The audio input device '${audio_device}' does not exist!"
        exit 3
    fi

    # Validate requested audio bitrate.
    if ! [[ "$audio_bitrate" =~ ^[0-9]+$ ]] || [ "$audio_bitrate" -lt 32 ] || [ "$audio_bitrate" -gt 320 ]; then
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Invalid audio bitrate!"
        echo "Please enter a value between 32 and 320."
        exit 4
    fi

    # Validate requested CRF.
    if ! [[ "$crf" =~ ^[0-9]+$ ]] || [ "$crf" -lt 0 ] || [ "$crf" -gt 51 ]; then
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Invalid constant rate factor '${crf}'!"
        echo "Please enter an integer between 0 and 51 (inclusive)."
        exit 5
    fi

    # Validate requested preset.
    local h265_preset
    local valid_preset=0
    for h265_preset in "${h265_presets[@]}"; do
        if [[ "$h265_preset" == "$preset" ]]; then
            valid_preset=1
            break
        fi
    done

    if [[ "$valid_preset" -eq 0 ]]; then
        local valid
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Invalid H.264 preset '${preset}'!"
        echo "Valid Presets:"
        for valid in "${h265_presets[@]}"; do
            echo "  - '${valid}'"
        done
        exit 6
    fi

    # Validate path to requested output directory.
    if [[ "$output_directory" =~ ^~(/.*)?$ ]]; then
        output_directory="${HOME}/${output_directory:2}"
    elif [[ "$output_directory" =~ ^~[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$ ]]; then
        local username
        local rest_of_path
        local user_home
        username=$(echo "$output_directory" | cut -d'/' -f1 | cut -d'~' -f2)
        rest_of_path=$(echo "$output_directory" | cut -d'/' -f2-)
        user_home=$(getent passwd "$username" | cut -d: -f6)

        if [[ -n "$user_home" ]]; then
            output_directory="${user_home}/${rest_of_path}"
        else
            echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Home folder for user '${username}' does not exist!"
            exit 7
        fi
    fi

    if [[ "$output_directory" =~ $illegal_chars ]]; then
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Output directory '${output_directory}' contains illegal characters!"
        echo "The following characters are not allowed in the output directory:"
        echo "< > : \" | ? *"
        echo "Please enter a valid path to the desired output directory."
        exit 8
    fi

    if [ ! -d "$output_directory" ]; then
        echo -e "${ANSI_YELLOW}[WARN]${ANSI_CLEAR} Output directory '${output_directory}' does not exist!"
        echo "Creating: '${output_directory}'..."

        # Attempt to create the directory.
        if ! mkdir -p "$output_directory"; then
            echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Failed to create output directory!"
            exit 9
        fi
    else
        # Check if the directory is writable.
        if [ ! -w "$output_directory" ]; then
            echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Output directory exists, but is not writable!"
            exit 10
        fi
    fi

    # Validate requested output file name.
    if ! [[ "$output_file_name" =~ ^[0-9a-zA-Z._-]+$ ]]; then
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} The output file name must not contain illegal characters!"
        echo "Ensure the output file name only contains letters, numbers, underscores, hyphens and periods."
        exit 11
    fi

    if [[ ! "$output_file_name" =~ \.ts$ ]]; then
        # Append '.ts' if absent.
        echo -e "${ANSI_YELLOW}[WARN]${ANSI_CLEAR} The '.ts' file extension will be appended to '${output_file_name}'!"
        output_file_name="${output_file_name}.ts"
    fi

    # Combine directory and file name to create output path.
    output_directory="${output_directory%/}" # Remove trailing '/' (if it exists).
    output_path="${output_directory}/${output_file_name}"

    # Check whether a file at the requested output path already exists.
    if [ -e "$output_path" ] || [ -e "${output_path%.*}.mp4" ] || [ -e "${output_path%.*}.log" ]; then
        local user_choice
        echo -e "${ANSI_YELLOW}[WARN]${ANSI_CLEAR} File(s) with the same name already exist at '${output_path}'!"
        read -r -p "Do you want to overwrite them? (y/n): " user_choice
        if [[ ! "$user_choice" =~ ^[yY]$ ]]; then
            echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Operation cancelled by user!"
            exit 12
        fi
    fi

    echo -e "${ANSI_GREEN}[DONE]${ANSI_CLEAR} Valid user input was provided!"
}

# Function to check the input video characteristics (i.e. resolution and frame rate.)
function get_video_specs() {
    # Notify user.
    echo ""
    echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} Detecting Video Standard (Resolution + Framerate)..."

    # Request specifications of video input device.
    video_input_info=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of default=noprint_wrappers=1 "$video_device" 2>/dev/null)
    video_input_width=$(echo "$video_input_info" | grep 'width=' | cut -d'=' -f2)   # Example: Grab '720' from 'width=720'.
    video_input_height=$(echo "$video_input_info" | grep 'height=' | cut -d'=' -f2) # Example: Grab '576' from 'height=576'.
    video_resolution="${video_input_width}x${video_input_height}"
    frame_rate=$(echo "$video_input_info" | grep 'r_frame_rate=' | cut -d'=' -f2 | awk -F'/' '{print $1/$2}') # Example: Grab '25' from 'r_frame_rate=25/1'.

    # Determine whether 'PAL' or 'NTSC'.
    if [[ "$video_resolution" == "720x576" ]] && [[ "$frame_rate" == "25" ]]; then
        video_standard="PAL"
    elif [[ "$video_resolution" == "720x480" ]] && [[ "$frame_rate" == "29.97" ]]; then
        video_standard="NTSC"
    else
        local user_choice
        video_standard="UNKNOWN"
        echo -e "${ANSI_YELLOW}[WARN]${ANSI_CLEAR} Unsupported video standard detected!"
        read -r -p "Continue anyway? (y/n): " user_choice
        if [[ ! "$user_choice" =~ ^[yY]$ ]]; then
            echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Operation cancelled by user!"
            exit 13
        fi
    fi

    # Inform user of detected video standard.
    echo ""
    echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} Detected Video Standard: ${ANSI_GREY}${video_standard} (${video_resolution}) [${frame_rate} fps]${ANSI_CLEAR}"
    echo ""
}

# Function to check whether VAAPI is available, returning the render device address.
function check_vaapi() {
    local hw_accel_features=""    # Stores output of 'ffmpeg -hwaccels'.
    local vaapi_device=""         # Stores address of VAAPI render device.

    # Query FFMPEG to identify hardware acceleration options.
    hw_accel_features=$(ffmpeg -hwaccels 2>/dev/null)

    # Check for VAAPI support.
    if echo "$hw_accel_features" | grep -q "vaapi"; then
        # Identify the correct path to the VAAPI render device in '/dev/dri/'.
        local device
        for device in /dev/dri/renderD*; do
            # Use 'udevadm' to check if the device is related to a GPU.
            if udevadm info --query=all --name="$device" | grep -iq "drm"; then
                # Use the first valid device found.
                vaapi_device="$device"
                break
            fi
        done
    fi

    # Return VAAPI render device.
    echo "$vaapi_device"
}

# Function to construct the capture command.
function construct_ffmpeg_command() {
    # Check whether VAAPI hardware acceleration is available.
    local vaapi_device
    vaapi_device=$(check_vaapi)

    if [ -n "$vaapi_device" ]; then
        local user_choice
        echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} VAAPI-based hardware acceleration is available!"
        read -r -p "Do you wish to utilise hardware acceleration? (y/n): " user_choice
        if [[ ! "$user_choice" =~ ^[yY]$ ]]; then
            echo -e "\n${ANSI_YELLOW}[WARN]${ANSI_CLEAR} Hardware acceleration disabled!"
            echo -e "${ANSI_YELLOW}[WARN]${ANSI_CLEAR} Software-based encoding may incur a performance penalty!"
            vaapi_device=""
        else
            echo -e "\n${ANSI_YELLOW}[WARN]${ANSI_CLEAR} The '-preset' parameter will be ignored with VAAPI!"
        fi
    fi

    # Configure VAAPI if a valid render device was identified.
    if [ -n "$vaapi_device" ]; then
        # VAAPI Key Differences
        #   - '-hwaccel vaapi' added.
        #   - '-preset' removed (VAAPI doesn't have direct presets).
        #   - '-vaapi_device' is specified using '/dev/dri/' path.
        #   - '-qp' used instead of 'crf'.
        #   - '-pix_fmt' specified as 'nv12' instead of 'yuv420p'.
        #   - '-vf' expanded to include 'format=nv12,hwupload' alongside 'setfield=tff'.
        ffmpeg_command=(
            # Video Capture Settings
            ffmpeg -f v4l2                             # Use Video4Linux2 (v4l2) for video capture.
            -video_size "$video_resolution"            # Set the resolution to 720x576 (PAL VHS standard).
            -input_format yuyv422                      # Use YUYV422 pixel format (common for USB capture devices).
            -i "$video_device"                         # Specify the video input device (the USB video grabber).

            # VAAPI
            -hwaccel vaapi                             # Enable VAAPI hardware acceleration.
            -vaapi_device "$vaapi_device"              # Specify path to VAAPI render device.

            # Audio Capture Settings
            -f alsa                                    # Use ALSA (Advanced Linux Sound Architecture) for audio capture.
            -ac 2 -channel_layout stereo               # Capture 2 channels (stereo audio).
            -ar 48000                                  # Set the audio sample rate to 48kHz.
            -i "$audio_device"                         # Specify the audio input device (the USB audio grabber).
            -af aresample=async=1                      # Resample the audio to keep it in sync with the video by introducing small adjustments.

            # Video Codec & Encoding Settings
            -c:v h265_vaapi                            # Use H.264 (HEVC) video codec with VAAPI hardware acceleration.
            -r "$frame_rate"                           # Set the output frame rate.
            -fps_mode cfr                              # Frames will be duplicated and dropped to achieve exactly the requested constant frame rate.
            -qp "$crf"                                 # Set Quantization Parameter.
            -pix_fmt nv12                              # Specify nv12 pixel format.
            -use_wallclock_as_timestamps 1             # Synchronise the input streams based on the system clock (this will enforce monotonic timestamps).

            # Interlacing & Field Order Settings
            -vf "format=nv12,hwupload,setfield=tff"    # Use nv12 pixel format + Use VRAM on GPU + Set top-field-first (VHS tapes are usually top-field first).
            -flags +ilme+ildct                         # Enable interlaced motion estimation and DCT for interlaced video.
            -weightp 0                                 # Disable weighted prediction given interlaced nature of input video stream.

            # Audio Codec & Encoding Settings
            -c:a aac                                   # Use AAC codec for audio encoding (widely supported).
            -b:a "${audio_bitrate}k"                   # Set the audio bitrate to 192 kbps for good stereo quality.

            # Output
            -buffer_size 250k                          # Allocate a 250kb memory buffer to store incoming data prior to processing.
            -f mpegts                                  # Specify MPEG-TS container format.
            -                                          # Ensure output is passed to stdout (rather than a file).
        )
    else
        ffmpeg_command=(
            # Video Capture Settings
            ffmpeg -f v4l2                             # Use Video4Linux2 (v4l2) for video capture.
            -video_size "$video_resolution"            # Set the resolution to 720x576 (PAL VHS standard).
            -input_format yuyv422                      # Use YUYV422 pixel format (common for USB capture devices).
            -i "$video_device"                         # Specify the video input device (the USB video grabber).

            # Audio Capture Settings
            -f alsa                                    # Use ALSA (Advanced Linux Sound Architecture) for audio capture.
            -ac 2 -channel_layout stereo               # Capture 2 channels (stereo audio).
            -ar 48000                                  # Set the audio sample rate to 48kHz.
            -i "$audio_device"                         # Specify the audio input device (the USB audio grabber).
            -af aresample=async=1                      # Resample the audio to keep it in sync with the video by introducing small adjustments.

            # Video Codec & Encoding Settings
            -c:v libx265                               # Use H.264 (HEVC) video codec.
            -r "$frame_rate"                           # Set the output frame rate.
            -fps_mode cfr                              # Frames will be duplicated and dropped to achieve exactly the requested constant frame rate.
            -crf "$crf"                                # Set Constant Rate Factor.
            -preset "$preset"                          # Specify H.264 encoding preset.
            -pix_fmt yuv420p                           # Ensure YUV 4:2:0 pixel format for wide compatibility.
            -use_wallclock_as_timestamps 1             # Synchronise the input streams based on the system clock (this will enforce monotonic timestamps).

            # Interlacing & Field Order Settings
            -vf "setfield=tff"                         # Set top-field-first (VHS tapes are usually top-field first).
            -flags +ilme+ildct                         # Enable interlaced motion estimation and DCT for interlaced video.
            -weightp 0                                 # Disable weighted prediction given interlaced nature of input video stream.

            # Audio Codec & Encoding Settings
            -c:a aac                                   # Use AAC codec for audio encoding (widely supported).
            -b:a "${audio_bitrate}k"                   # Set the audio bitrate to 192 kbps for good stereo quality.

            # Output
            -buffer_size 250k                          # Allocate a 250kb memory buffer to store incoming data prior to processing.
            -f mpegts                                  # Specify MPEG-TS container format.
            -                                          # Ensure output is passed to stdout (rather than a file).
        )
    fi
}

# Function to preview and confirm execution of the capture command.
function execute_capture() {
    local user_choice
    local final_command
    final_command="${ffmpeg_command[*]} > >(tee \"$output_path\" > \"$named_pipe\") 2>\"${output_path%.*}.log\" &"
    echo -e "\n${ANSI_BLUE}[INFO]${ANSI_CLEAR} The following command will be executed:"
    echo ""
    echo "----------------------------------------------------------------"
    echo -e "${ANSI_GREY}${final_command}${ANSI_CLEAR}"
    echo "----------------------------------------------------------------"
    echo ""
    read -r -p "Do you want to proceed with this command? (y/n): " user_choice
    if [[ ! "$user_choice" =~ ^[yY]$ ]]; then
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Operation cancelled by user!"
        exit 14
    fi

    # Advise user.
    echo -e "\n${ANSI_BLUE}[INFO]${ANSI_CLEAR} Capturing..."
    echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} Complete the capture by requesting SIGINT (Ctrl + C)."

    # Create log.
    {
        echo "################  INPUT VIDEO STANDARD  ################"
        echo "${video_standard} (${video_resolution}) [${frame_rate} fps]"
        echo ""
        echo "################       VHS TO .TS       ################"
        echo "----------------     FFMPEG COMMAND     ----------------"
        echo "${ffmpeg_command[*]} > >(tee \"$output_path\" > \"$named_pipe\") 2>\"${output_path%.*}.log\" &"
        echo ""
        echo "---------------- FFMPEG OUTPUT (STDERR) ----------------"
    } > "${output_path%.*}.log"

    # Run FFMPEG.
    # Split stdout using 'tee' to both the output file and the named pipe.
    # Ensure stderr is instead captured within a log file.
    "${ffmpeg_command[@]}" > >(tee "$output_path" > "$named_pipe") 2>>"${output_path%.*}.log" &
    ffmpeg_pid=$!

    # Start FFPLAY.
    # This will provide a 'live preview' of what FFMPEG is capturing.
    ffplay "$named_pipe" -window_title "TapeShift VHS Capture Preview" -fflags nobuffer &>/dev/null &
    ffplay_pid=$!

    # Prevent script from exiting until user issues SIGINT.
    # Execution should only push past this point once either:
    # 1. 'exit_script' is called via SIGINT (Ctrl + C).
    # 2. Unexpected termination of FFMPEG.
    wait "$ffmpeg_pid" 2>/dev/null

    # If flag remains unset, FFMPEG/FFPLAY terminated without user-requested SIGINT.
    if [[ "$ff_error_flag" -eq 1 ]]; then
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} FFMPEG and/or FFPLAY command failed!"
        echo "Please see the log at '${output_path%.*}.log' for details."
        ff_error_flag=0
        exit 15
    fi
}

# Function to finalise the capture from '.ts' to '.mp4'.
function finalise_capture() {
    # Notify user.
    echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} Finalising capture..."

    # Convert the capture file to '.mp4' without re-encoding.
    {
        echo ""
        echo "################       .TS TO MP4       ################"
        echo "----------------     FFMPEG COMMAND     ----------------"
        echo "ffmpeg -y -i \"$output_path\" -c:a copy -c:v copy \"${output_path%.*}.mp4\" 2>>\"${output_path%.*}.log\""
        echo ""
        echo "---------------- FFMPEG OUTPUT (STDERR) ----------------"
    } >> "${output_path%.*}.log"
    ffmpeg -y -i "$output_path" -c:a copy -c:v copy "${output_path%.*}.mp4" 2>>"${output_path%.*}.log"

    # Remove the original capture file.
    if [ -f "${output_path%.*}.mp4" ]; then
        rm "$output_path"
    else
        echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} Failed to finalise capture!"
        echo "A partial, potentially corrupt capture may exist at '${output_path}'."
        echo "Please see the log at '${output_path%.*}.log' for details."
        ff_error_flag=0
        exit 16
    fi
}

# Function to trim the captured video.
function trim_output() {
    # Ask user if they would like to trim the resulting capture.
    local user_choice
    read -r -p "Would you like to trim the capture? (y/n): " user_choice

    if [[ "$user_choice" =~ ^[yY]$ ]]; then
        # Open the capture.
        local media_player_pid
        xdg-open "${output_path%.*}.mp4" &>/dev/null &
        media_player_pid=$?

        # Request trimming parameters from user.
        echo "Please specify the start and end trim positions as either:"
        echo "1. The number of seconds (e.g., 10, 10.5, 10s, 10ms, 10us)"
        echo "2. The time in hours, minutes and seconds (e.g., 01:30:15, 1:30:15.5)"
        local start_param
        local end_param

        # Validate user input.
        # There are two accepted formats for expressing time duration:
        # 1. [HH:]MM:SS[.m...] --> EXAMPLES: "01:30:15", "1:30:15.5", etc.
        #     - HH expresses the number of hours (optional).
        #     - MM expresses the number of minutes for a maximum of 2 digits.
        #     - SS expresses the number of seconds for a maximum of 2 digits.
        #     - The 'm' at the end expresses decimal value for SS (optional).
        # 2. S+[.m...][s|ms|us] --> EXAMPLES: "55", "0.2", "200ms", "200000us", etc.
        #     - S expresses the number of seconds/milliseconds/microseconds (with an optional decimal part 'm').
        #     - The optional literal suffixes 's', 'ms' or 'us' indicate 'seconds', 'milliseconds' or 'microseconds'.
        while true; do
            read -r -p "Trim start position: " start_param
            
            # Validate start_param.
            if [[ "$start_param" =~ ^([0-9]*:[0-5][0-9]:[0-5][0-9]([.][0-9]+)?)|([0-9]+([.][0-9]+)?(s|ms|us)?)$ ]]; then
                break
            else
                echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} INVALID TRIM START POSITION!"
            fi
        done
        
        while true; do
            read -r -p "Trim end position: " end_param

            # Validate end_param.
            if [[ "$end_param" =~ ^([0-9]*:[0-5][0-9]:[0-5][0-9]([.][0-9]+)?)|([0-9]+([.][0-9]+)?(s|ms|us)?)$ ]]; then
                break
            else
                echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} INVALID TRIM END POSITION!"
            fi
        done

        # Gracefully close FFPLAY with SIGTERM.
        kill -SIGTERM "$media_player_pid"
        wait "$media_player_pid"

        # Confirm selection.
        echo -e "\n${ANSI_BLUE}[INFO]${ANSI_CLEAR} The following command will be executed:"
        echo ""
        echo "----------------------------------------------------------------"
        echo -e "${ANSI_GREY}ffmpeg -ss ${start_param} -i \"${output_path%.*}.mp4\" -to ${end_param} -c copy \"${output_path%.*}_TRIMMED.mp4\" 2>>\"${output_path%.*}.log\"${ANSI_CLEAR}"
        echo "----------------------------------------------------------------"
        echo ""
        echo -e "${ANSI_YELLOW}[WARN]${ANSI_CLEAR} The untrimmed capture at '${output_path%.*}.mp4' will be permanently deleted if the trimming process is successful!"
        read -r -p "Do you want to proceed with this command? (y/n): " user_choice
        if [[ "$user_choice" =~ ^[yY]$ ]]; then
            # Notify user.
            echo -e "\n${ANSI_BLUE}[INFO]${ANSI_CLEAR} Trimming capture..."

            # Write to log.
            {
                echo ""
                echo "################    CAPTURE TRIMMING    ################"
                echo "----------------     FFMPEG COMMAND     ----------------"
                echo "ffmpeg -copyts -ss ${start_param} -i \"${output_path%.*}.mp4\" -to ${end_param} -map 0 -c copy \"${output_path%.*}_TRIMMED.mp4\""
                echo ""
                echo "---------------- FFMPEG OUTPUT (STDERR) ----------------"
            } >> "${output_path%.*}.log"

            # Run FFMPEG command.
            ffmpeg -copyts -ss ${start_param} -i "${output_path%.*}.mp4" -to ${end_param} -map 0 -c copy "${output_path%.*}_TRIMMED.mp4" 2>>"${output_path%.*}.log"

            # Check output.
            if [ -f "${output_path%.*}_TRIMMED.mp4" ]; then
                echo -e "${ANSI_BLUE}[INFO]${ANSI_CLEAR} Moving trimmed capture to '${output_path%.*}.mp4'."
                rm "${output_path%.*}.mp4"
                mv "${output_path%.*}_TRIMMED.mp4" "${output_path%.*}.mp4"
            else
                echo -e "${ANSI_RED}[ERR]${ANSI_CLEAR} FAILED TO TRIM CAPTURE!"
                echo "The untrimmed capture at '${output_path%.*}.mp4' should still be playable."
                echo "Please see the log at '${output_path%.*}.log' for details."
                ff_error_flag=0
                exit 17
            fi
        fi
    fi
}

##################
# MAINLINE LOGIC #
##################

# Welcome the user.
print_title

# Check if all dependencies are available.
check_dependencies

# Create the named pipe.
create_named_pipe

# Find and display available audio and video input devices.
display_input_devices

# Capture user input.
capture_user_input

# Check user input.
check_user_input

# Check video input characteristics.
get_video_specs

# Construct the FFMPEG command.
construct_ffmpeg_command

# Allow the user to preview and approve the command prior to execution.
execute_capture

# Finalise the capture.
finalise_capture

# Trim capture.
trim_output

# Notify user.
echo -e "${ANSI_GREEN}[DONE]${ANSI_CLEAR} Finished!"

# Log completion.
echo -e "\n################        FINISHED        ################" >> "${output_path%.*}.log"
