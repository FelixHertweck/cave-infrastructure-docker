# Windows Image Builder (Dockerized)

This directory provides a fully containerized and automated environment for building Windows `.qcow2` images. It wraps the `windows-image-generation` tools from the [cave-images repository](https://gitlab.opencode.de/BSI-Bund/cave/cave-images) into an easy-to-use Docker setup.

By default, the underlying OpenStack/QEMU image generation requires manual interaction via a SPICE client to hit "Press any key to boot from CD or DVD", as well as confirming language settings and bypassing product key prompts depending on the ISO used. This Docker wrapper fully automates these steps using a QEMU monitor socket and simulated keystrokes, making the build process completely unattended.

## Prerequisites

1.  **Docker & Docker Compose**: Ensure you have Docker installed.
2.  **KVM Hardware Virtualization**: The host machine must have native KVM enabled (`/dev/kvm` must exist and be accessible).

## Required ISO Files

You need to provide the Windows installation media and the VirtIO drivers. For detailed information on where to obtain these, please refer to the [upstream requirements documentation](https://gitlab.opencode.de/oc000142689289/cave-images/-/tree/main/windows-image-generation#requirements). Place them into the `iso-images/` directory:

*   `install_client.iso` (for Windows 11) or `install_server.iso` (for Windows Server 2025/2022).
*   `virtio-win.iso` (VirtIO drivers, usually from Fedora).

Hint: You can find links to the windows eval images [here](https://github.com/matthewomccorkle/windows_eval_links)

## How to Build an Image

1. Ensure your ISO files are correctly placed in the `iso-images/` folder.
2. If you want to build a different variant than the default `client` (Windows 11), edit the `VARIANT` environment variable in the `docker-compose.yml`. Adjust the ISO mount names accordingly.

   Available variants and required installation media:

   | VARIANT | ISO file | Description |
   | --- | --- | --- |
   | `client` | `install_client.iso` | Windows 11 installation media |
   | `server2025` | `install_server.iso` | Windows Server 2025 installation media |
   | `server` / `server2022` | `install_server2022.iso` | Windows Server 2022 installation media |

3. Start the build process:
   ```bash
   # Build the default variant (set in docker-compose.yml)
   docker compose up

   # or build a different variant
   VARIANT=server2025 docker compose up
   # or
   VARIANT=server2022 docker compose up
   ```

The script will automatically start the container, boot QEMU, simulate the necessary key presses to bypass the manual setup screens, and start the unattended Windows installation. Once the installation finishes, the final `.qcow2` image will be copied to your `output/` folder and the container will exit.

## Troubleshooting & Manual Intervention

Because the automation relies on fixed delays (e.g., waiting 60 seconds for WinPE to boot), it might fail if your host machine is exceptionally slow or if the Windows ISO behaves differently than expected.

If the setup seems stuck or the final image is not being generated, you can always intervene manually:

1. Open your web browser and go to: **[http://localhost:8080/vnc.html](http://localhost:8080/vnc.html)**
2. Click **Connect**.
3. You will see the live screen of the QEMU VM. 
4. If the automation missed a prompt (e.g., the language selection or the product key screen), you can simply use your mouse and keyboard inside the browser to click "Next", "I don't have a product key", or select the OS edition.
5. Once you pass the blocking screen, the `autounattend.xml` will pick up the rest of the installation automatically.