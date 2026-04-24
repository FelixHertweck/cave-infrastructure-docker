#!/bin/bash
set -e

# Default variant to 'client' if not set
VARIANT=${VARIANT:-client}
export SPICE_PORT=5900

echo "Starting noVNC on port 8080..."
# Start websockify for noVNC - QEMU VNC 0 listens on 5900
websockify --web /usr/share/novnc/ 8080 localhost:5900 &

echo "Patching bootstrap.sh to use VNC instead of SPICE..."
# Replace SPICE with VNC so we can use noVNC in the browser
# VNC display :0 corresponds to port 5900
sed -i 's/-spice port=$SPICE_PORT,addr=127.0.0.1,disable-ticketing=on,image-compression=auto_glz/-vnc 127.0.0.1:0/g' /work/bootstrap.sh

# Swap stdio monitor with a unix socket so we can send QMP/monitor commands with netcat
echo "Configuring QEMU monitor to use a UNIX socket..."
sed -i 's/-monitor stdio/-monitor unix:\/work\/qemu-monitor.sock,server,nowait/g' /work/bootstrap.sh

echo "Symlinking ISO images from /work/iso-images to /work..."
# Create symbolic links for all ISO files so bootstrap.sh finds them in its working directory
ln -s /work/iso-images/*.iso /work/ 2>/dev/null || true

echo "Running bootstrap.sh for variant $VARIANT in the background..."
# Execute the bootstrap script in background so we can send the automated keystroke
bash /work/bootstrap.sh --variant $VARIANT &
BOOTSTRAP_PID=$!

echo "Waiting for the QEMU monitor socket to initialize..."
while [ ! -S /work/qemu-monitor.sock ]; do
    # check if process died early
    if ! kill -0 $BOOTSTRAP_PID 2>/dev/null; then
        echo "Error: QEMU process died before initializing."
        exit 1
    fi
    sleep 1
done

# Wait for QEMU and the VM to actually reach the CD-ROM boot prompt. 
# Depending on the system, this can take a few seconds. 
echo "Waiting 5 seconds for the VM to start and show the 'Press any key to boot from CD or DVD...' prompt..."
sleep 5

echo "Sending automated 'Enter' keypresses to QEMU via monitor to kickstart the installation..."
# Send 'sendkey ret' a few times to ensure we hit the time window
for i in {1..7}; do
    echo "Pressing Enter (Attempt $i/7)..."
    echo "sendkey ret" | nc -w 1 -U /work/qemu-monitor.sock || true
    sleep 1
done

echo "Automated keypress sequence complete for CD boot."

echo "You can monitor the progress via the noVNC interface at http://localhost:8080/vnc.html"

# Wait for the QEMU process to finish its installation and shut down
wait $BOOTSTRAP_PID

echo "Installation finished! Copying output image if /work/output is mounted..."
if [ -d "/work/output" ]; then
    cp -v *.qcow2 /work/output/
    echo "Image copied to output directory."
fi
