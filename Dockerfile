FROM debian:12

# Install dependencies
RUN apt-get update && apt-get install -y curl xz-utils libc6-dev && \
    rm -rf /var/lib/apt/lists/*

# Set up Zig
ARG ZIGVER=0.15.1
WORKDIR /deps
RUN curl -L https://ziglang.org/download/$ZIGVER/zig-x86_64-linux-$ZIGVER.tar.xz -o zig.tar.xz && \
    tar xf zig.tar.xz && \
    mv zig-x86_64-linux-$ZIGVER /usr/local/zig

ENV PATH="/usr/local/zig:${PATH}"

# Copy source directly into final image
WORKDIR /zortfolio
COPY . .

# Build the project
RUN zig build -Dcpu=baseline -Doptimize=ReleaseFast

# Default command
CMD ["./zig-out/bin/zortfolio"]
