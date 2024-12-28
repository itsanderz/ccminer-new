#!/bin/sh
sudo apt-get -y update
sudo apt-get -y upgrade
# Install additional dependencies including OpenCL for GPU support
sudo apt-get -y install libcurl4-openssl-dev libjansson-dev libomp-dev git screen nano jq wget \
    build-essential automake autoconf libtool cmake \
    opencl-headers ocl-icd-* pocl-opencl-icd \
    libgmp-dev libmpfr-dev \
    autoconf-archive

# Set up some performance optimization variables
export CFLAGS="-Ofast -march=armv8-a+crypto -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard -fomit-frame-pointer -flto"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-flto"

# Create working directories
mkdir -p ~/ccminer ~/ccminer_src

# Clone optimized ccminer fork with ARM/mobile support
cd ~/ccminer_src
git clone https://github.com/tpruvot/ccminer.git .
git submodule update --init --recursive

# Apply ARM-specific optimizations
cat << 'EOF' > configure.ac.patch
--- configure.ac.orig
+++ configure.ac
@@ -25,6 +25,9 @@
 AC_PROG_CC
 AC_PROG_CXX
 
+# Enable ARM NEON support
+AX_CHECK_COMPILE_FLAG(-mfpu=neon, [CXXFLAGS="$CXXFLAGS -mfpu=neon"])
+
 dnl Setup CUDA paths
 AC_ARG_WITH([cuda],
    [  --with-cuda=PATH    prefix where cuda is installed [default=/usr/local/cuda]])
EOF

patch -p0 < configure.ac.patch

# Configure build with optimizations
./autogen.sh
./configure \
    --with-crypto \
    --with-cuda=no \
    --with-opencl \
    CFLAGS="$CFLAGS" \
    CXXFLAGS="$CXXFLAGS" \
    LDFLAGS="$LDFLAGS"

# Build using all available cores
make -j$(nproc)

# Install the optimized binary
if [ -f ccminer ]; then
    cp ccminer ~/ccminer/
    chmod +x ~/ccminer/ccminer
fi

# Create optimized config for mobile mining
cat << EOF > ~/ccminer/config.json
{
    "pools": [
        {
            "name": "pool.verus.io",
            "url": "stratum+tcp://pool.verus.io:9999",
            "timeout": 150,
            "time-limit": 3600
        }
    ],
    "user": "WALLET_ADDRESS.WORKER_NAME",
    "algo": "verus",
    "threads": "$(nproc)",
    "cpu-priority": 2,
    "cpu-affinity": "0x555555",
    "gpu-id": 0,
    "gpu-threads": 2,
    "gpu-batch-size": 256,
    "intensity": 20,
    "worksize": 64,
    "api-allow": "0/0",
    "api-bind": "127.0.0.1:4068",
    "tune-full": true,
    "tune-config": "tune_config",
    "temperature-limit": 75,
    "temperature-target": 70,
    "auto-fan": true,
    "retry-pause": 20,
    "max-temp-retry": 3,
    "shares-limit": 0,
    "no-cpu": false,
    "no-gpu": false,
    "low-power": true
}
EOF

# Create an optimized startup script
cat << 'EOF' > ~/ccminer/start.sh
#!/bin/sh

# Set CPU governor to performance
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "performance" | sudo tee $cpu
done

# Set GPU frequency to maximum
if [ -f /sys/class/kgsl/kgsl-3d0/devfreq/max_freq ]; then
    echo "$(cat /sys/class/kgsl/kgsl-3d0/devfreq/max_freq)" | sudo tee /sys/class/kgsl/kgsl-3d0/devfreq/min_freq
fi

# Kill any existing mining sessions
screen -S CCminer -X quit 1>/dev/null 2>&1
screen -wipe 1>/dev/null 2>&1

# Start mining in new screen session
screen -dmS CCminer
screen -S CCminer -X stuff "nice -n -20 ~/ccminer/ccminer -c ~/ccminer/config.json 2>&1 | tee ~/ccminer/miner.log\n"

# Monitor temperature and throttle if needed
while true; do
    temp=$(cat /sys/class/thermal/thermal_zone0/temp)
    temp=$((temp/1000))
    if [ $temp -gt 75 ]; then
        echo "Temperature too high ($temp°C), throttling..."
        screen -S CCminer -X stuff $'\003'
        sleep 30
        screen -S CCminer -X stuff "~/ccminer/ccminer -c ~/ccminer/config.json\n"
    fi
    sleep 10
done &

echo "Mining started with optimizations"
echo "================================"
echo "Monitor: screen -x CCminer"
echo "Stop: screen -X -S CCminer quit"
EOF

chmod +x ~/ccminer/start.sh

# Optionally, verify GPU driver presence before forcing max GPU frequency
if [ ! -f /sys/class/kgsl/kgsl-3d0/devfreq/max_freq ]; then
    echo "Warning: GPU driver not found or not accessible. Skipping GPU frequency boost."
fi
