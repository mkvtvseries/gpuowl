gpuowl: gpuowl.cpp clwrap.h tinycl.h
	g++ -O2 -Wall -Werror -std=c++14 gpuowl.cpp -ogpuowl -lOpenCL -L/opt/amdgpu-pro/lib/x86_64-linux-gnu -L/c/Windows/System32
