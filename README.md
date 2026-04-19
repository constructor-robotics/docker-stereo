# docker-zed

A Docker setup for running the **Stereolabs ZED SDK + ROS 2 Jazzy + the ZED ROS 2 wrapper & examples**, all in one container.

Built on top of Stereolabs' official ZED SDK image (`stereolabs/zed:5.2-gl-devel-cuda12.8-ubuntu24.04`) — Ubuntu 24.04 + CUDA 12.8 + the ZED SDK pre-installed. On top of that this image adds:

- **ROS 2 Jazzy Jalisco** (desktop install — includes rviz2, rqt, demo nodes).
- **colcon** + `ros-dev-tools` + `rosdep`.
- The **[zed-ros2-wrapper](https://github.com/stereolabs/zed-ros2-wrapper)** built from source.
- The **[zed-ros2-examples](https://github.com/stereolabs/zed-ros2-examples)** built from source.
- A separate user workspace at `/root/user_ws` for your own packages.

> **Using the ZED as input to OHM mapping?** See [../docker-ohm/ZED_PIPELINE.md](../docker-ohm/ZED_PIPELINE.md) for the end-to-end stereo → OHM pipeline (topic selection, preprocessing, staged plan).

---

## What's in this folder

| File | Purpose |
| --- | --- |
| `Dockerfile` | Recipe: ZED SDK base + ROS 2 Jazzy + cloned ZED ROS 2 repos + colcon build. |
| `docker-compose.yml` | Declarative run config: GPU passthrough, X11, host networking for DDS. |
| `user_ws/` | Your ROS 2 workspace on the host. Bind-mounted as `/root/user_ws` in the container. |
| `README.md` | This file. |

---

## Prerequisites

1. **Docker** with the Compose plugin:
    ```bash
    sudo apt install docker.io docker-compose-v2
    sudo usermod -aG docker "$USER"
    newgrp docker
    ```

2. **NVIDIA GPU + nvidia-container-toolkit** (required — the ZED SDK needs CUDA):
    ```bash
    sudo apt install nvidia-container-toolkit
    sudo systemctl restart docker
    docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
    ```

3. **X11 access for GUI tools** (for rviz2, ZED_Explorer):
    ```bash
    xhost +local:docker
    ```
    Run this once per login session before launching GUI apps.

---

## Quick start

```bash
cd ~/cub_marine/optitrack-roboticslab-ws/docker-zed

# First time only — creates the host-side user workspace
mkdir -p user_ws/src

# Build the image (10–25 min first time: installs ROS 2 + builds ZED wrapper)
docker compose build

# Launch an interactive shell
docker compose run --rm zed
```

You're now inside the container with:
- ROS 2 Jazzy sourced
- The ZED wrapper workspace (`/root/ros2_ws`) sourced
- Your user workspace (`/root/user_ws`) sourced (if built)

Quick sanity checks:
```bash
ros2 --help
ros2 pkg list | grep zed         # should list zed_wrapper, zed_components, zed_interfaces, ...
nvidia-smi                       # GPU visible
```

---

## Launching the ZED camera as a ROS 2 node

Plug in your ZED camera, then inside the container:

```bash
# Replace zed2i with your model: zed, zedm, zed2, zed2i, zedx, zedxm
ros2 launch zed_wrapper zed_camera.launch.py camera_model:=zed2i

# In another host terminal:
docker exec -it zed-ros2 bash -l
ros2 topic list
rviz2     # if X11 is forwarded
```

---

## Two workspaces — what goes where

| Path | Contents | When to use |
| --- | --- | --- |
| `/root/ros2_ws` (in-image) | ZED wrapper + examples, pre-built. | Don't modify. Rebuilt by `docker compose build`. |
| `/root/user_ws` (host-mounted) | Your own packages — source persists on the host. | All your day-to-day work. |

Workflow for a new package:
```bash
# On the host
cd ~/cub_marine/optitrack-roboticslab-ws/docker-zed/user_ws/src
git clone https://github.com/.../my_pkg.git

# Inside the container
cd /root/user_ws
rosdep install --from-paths src --ignore-src -r -y
colcon build --symlink-install --cmake-args=-DCMAKE_BUILD_TYPE=Release
source install/setup.bash   # or just open a new shell — .bashrc auto-sources it
```

---

## The docker-compose.yml flags (what they do)

| Flag | Why |
| --- | --- |
| `privileged: true` | Needed for USB camera access (ZED is USB or GMSL). |
| `network_mode: host` | Makes ROS 2 DDS discovery work with host ROS nodes out of the box. |
| `ipc: host` | Enables shared-memory DDS transport for lower latency. |
| `pid: host` | Lets `ros2 node list` see ROS nodes running on the host (and vice versa). |
| `/tmp/.X11-unix` volume | X11 forwarding for GUI apps. |
| `/dev` volume | Exposes all host devices — required for ZED USB enumeration. |
| `deploy.reservations.devices` (nvidia) | GPU passthrough — equivalent of `--gpus all`. |
| `NVIDIA_DRIVER_CAPABILITIES=all` | ZED SDK needs compute + video + graphics caps. |

---

## Common tasks

**Open a second shell into the running container:**
```bash
docker exec -it zed-ros2 bash -l
```

**Stop and remove the container:**
```bash
docker compose down
```

**Rebuild the image after editing the Dockerfile:**
```bash
docker compose build
```

**Force the ZED wrapper to pull latest upstream and rebuild:**
```bash
docker compose build --no-cache     # nukes all layers; slow
```
(A cleaner alternative is to `cd /root/ros2_ws/src/zed-ros2-wrapper && git pull && cd /root/ros2_ws && colcon build` inside a live container, but the changes are lost when the container is removed.)

**Run a one-shot command without a shell:**
```bash
docker compose run --rm zed ros2 topic list
```

---

## Troubleshooting

**`docker compose build` fails at the `colcon build` step:**
Usually a missing dep the rosdep rules didn't catch. Read the failing package's log above the error, `apt install` the missing `-dev` package in the Dockerfile's package-install layer, and rebuild.

**`ros2 launch zed_wrapper ...` says no camera found:**
- Is the camera plugged in? Check `lsusb | grep -i stereolabs` on the host *and* inside the container.
- Compose mounts `/dev` and sets `privileged: true` — if you removed either, put it back.
- Try `ZED_Explorer` from inside the container to isolate whether it's a ROS problem or an SDK problem.

**rviz2 opens a black window or crashes:**
- Did you run `xhost +local:docker` on the host?
- Is `DISPLAY` set on the host? (`echo $DISPLAY`)
- NVIDIA drivers: confirm `nvidia-smi` works inside the container.

**ROS 2 topics don't appear between the container and a host ROS node:**
- Both ends need the same `ROS_DOMAIN_ID` (defaults to `0`).
- With `network_mode: host`, discovery should "just work" on the same machine.
- If you're on separate machines, both need to be on the same subnet and firewall-allow UDP multicast.

**`rosdep install` fails with "ERROR: resource not found":**
```bash
rosdep update
```
The apt cache was wiped during image build — `rosdep update` is fine to rerun inside the container.

**Image is huge (>15 GB):**
That's expected — ZED SDK + CUDA + ROS 2 desktop + two built workspaces. To trim: swap `ros-jazzy-desktop` for `ros-jazzy-ros-base` in the Dockerfile if you don't need rviz/rqt.

---

## Switching to a different ZED SDK / CUDA version

Change the `FROM` line at the top of the `Dockerfile`:
```dockerfile
FROM stereolabs/zed:<sdk>-gl-devel-cuda<cuver>-ubuntu24.04
```
Browse tags: <https://hub.docker.com/r/stereolabs/zed/tags>. Stay on `ubuntu24.04` tags to keep ROS 2 Jazzy compatibility — other Ubuntu versions need a different ROS distro (Humble for 22.04, etc.).

---

## References

- ZED SDK Docker: <https://www.stereolabs.com/docs/docker>
- ZED ROS 2 wrapper: <https://github.com/stereolabs/zed-ros2-wrapper>
- ZED ROS 2 examples: <https://github.com/stereolabs/zed-ros2-examples>
- ROS 2 Jazzy install: <https://docs.ros.org/en/jazzy/Installation.html>
