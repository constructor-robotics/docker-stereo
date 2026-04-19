# ---------------------------------------------------------------------------
# ZED SDK + ROS 2 Humble + zed-ros2-wrapper + zed-ros2-examples
#
# Base image already ships the ZED SDK 5.2, CUDA 12.8, and OpenGL libs on
# Ubuntu 22.04 (Jammy), which is the correct Ubuntu for ROS 2 Humble.
#
# CUDA driver libs (libcuda.so.1, libnvcuvid, libnvidia-encode) are injected
# by the NVIDIA container runtime at *runtime* and are absent at build time.
# The workaround is to point the linker at CUDA's stub libraries and allow
# undefined symbols in shared libs during the final link — the official
# Stereolabs Docker recipe does exactly this. The real drivers resolve the
# symbols when the container runs with `--gpus all`.
# ---------------------------------------------------------------------------
FROM stereolabs/zed:5.2-gl-devel-cuda12.8-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ROS_DISTRO=humble
ENV ROS_DISTRO=${ROS_DISTRO} \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Etc/UTC

# The NVIDIA runtime needs these to expose GL + video + compute at runtime.
ENV NVIDIA_DRIVER_CAPABILITIES=compute,video,utility,graphics \
    NVIDIA_VISIBLE_DEVICES=all

ENV DISPLAY=${DISPLAY}

# ---------------------------------------------------------------------------
# 1. Locale + repo prerequisites
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        locales \
        curl \
        gnupg2 \
        lsb-release \
        software-properties-common \
        ca-certificates \
        apt-utils \
        dialog \
    && locale-gen en_US en_US.UTF-8 \
    && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
    && add-apt-repository universe \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. Extra system packages the ZED wrapper + examples expect
#    (matches the official stereolabs desktop Dockerfile + examples deps)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        jq \
        less \
        libgomp1 \
        libopencv-dev \
        libpng-dev \
        libpq-dev \
        libusb-1.0-0-dev \
        python3 \
        python3-dev \
        python3-pip \
        python3-wheel \
        sudo \
        udev \
        usbutils \
        wget \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 3. ROS 2 Humble apt source + signing key
#    Uses the official ros-apt-source .deb, auto-detecting the Ubuntu codename.
# ---------------------------------------------------------------------------
RUN export ROS_APT_SOURCE_VERSION=$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F "tag_name" | awk -F\" '{print $4}') \
    && curl -L -o /tmp/ros2-apt-source.deb \
        "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.$(. /etc/os-release && echo $VERSION_CODENAME)_all.deb" \
    && apt-get update && apt-get install -y /tmp/ros2-apt-source.deb \
    && rm /tmp/ros2-apt-source.deb \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 4. ROS 2 Humble desktop + dev tooling
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-desktop \
        ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
        ros-${ROS_DISTRO}-rmw-fastrtps-cpp \
        ros-dev-tools \
        python3-colcon-common-extensions \
        python3-rosdep \
        python3-argcomplete \
        python3-flake8-docstrings \
        python3-pytest-cov \
    && rosdep init \
    && rm -rf /var/lib/apt/lists/*

# Python packages the wrapper / examples / colcon resolve via pip.
# --break-system-packages is required on Ubuntu 24.04 (PEP 668).
RUN pip3 install --no-cache-dir \
        argcomplete \
        empy \
        lark \
        numpy \
        opencv-python-headless

# ---------------------------------------------------------------------------
# 5. Shell bootstrap — source ROS + both workspaces in every interactive shell
# ---------------------------------------------------------------------------
RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc \
    && echo 'export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}' >> /root/.bashrc \
    && echo '[ -f /root/ros2_ws/install/setup.bash ] && source /root/ros2_ws/install/setup.bash' >> /root/.bashrc \
    && echo '[ -f /root/user_ws/install/setup.bash ] && source /root/user_ws/install/setup.bash' >> /root/.bashrc

# ---------------------------------------------------------------------------
# 6. Clone ZED ROS 2 wrapper + examples
# ---------------------------------------------------------------------------
WORKDIR /root/ros2_ws
RUN mkdir -p /root/ros2_ws/src \
    && cd /root/ros2_ws/src \
    && git clone --recursive https://github.com/stereolabs/zed-ros2-wrapper.git \
    && git clone --recursive https://github.com/stereolabs/zed-ros2-examples.git

# ---------------------------------------------------------------------------
# 7. Install ROS deps via rosdep
#    - scout_description is skipped (it's a non-ROS dep pulled by one example
#      that isn't available via rosdep for Jazzy).
# ---------------------------------------------------------------------------
RUN apt-get update \
    && rosdep update --rosdistro=${ROS_DISTRO} \
    && bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash \
        && rosdep install --from-paths src --ignore-src -r -y \
           --rosdistro=${ROS_DISTRO} \
           --skip-keys scout_description" \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 8. Build the wrapper + examples.
#    CUDA stub path + --allow-shlib-undefined mirrors the official
#    stereolabs/zed-ros2-wrapper Dockerfile — this is what makes the build
#    succeed without the runtime CUDA driver libs present.
# ---------------------------------------------------------------------------
RUN bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build \
        --parallel-workers $(nproc) \
        --symlink-install \
        --event-handlers console_direct+ \
        --base-paths src \
        --cmake-args \
            ' -DCMAKE_BUILD_TYPE=Release' \
            ' -DCMAKE_LIBRARY_PATH=/usr/local/cuda/lib64/stubs' \
            ' -DCMAKE_CXX_FLAGS=-Wl,--allow-shlib-undefined'"

WORKDIR /root/ros2_ws

# ---------------------------------------------------------------------------
# 9. Entry
# ---------------------------------------------------------------------------
CMD ["/bin/bash", "-l"]
