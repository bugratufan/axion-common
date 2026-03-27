# Docker Setup for Axion Common

This project includes Docker support to provide a consistent, reproducible environment for VHDL simulation with GHDL 4.1.0 and cocotb testing.

## Quick Start

### Local Testing with Docker

```bash
# Run VHDL tests
./docker-run.sh make test

# Run cocotb (Python) tests
./docker-run.sh make cocotb-test

# Interactive shell
./docker-run.sh bash

# Run arbitrary command
./docker-run.sh make clean all
```

### Manual Docker Commands

```bash
# Build the image
docker build -t axion-common:latest .

# Run tests
docker run --rm -v $(pwd):/workspace axion-common:latest make test

# Interactive shell
docker run --rm -it -v $(pwd):/workspace axion-common:latest bash
```

## GitHub Actions (CI/CD)

The CI/CD pipeline automatically:
1. Builds the Docker image for each commit to `main` or `develop`
2. Pushes it to GitHub Container Registry (ghcr.io)
3. Uses the image for all test jobs

Push the image to ghcr.io:

```bash
# Build and tag
docker build -t ghcr.io/bugratufan/axion-common:latest .

# Login to ghcr.io (requires GitHub token)
docker login ghcr.io

# Push
docker push ghcr.io/bugratufan/axion-common:latest
```

## Image Contents

The Docker image includes:
- **GHDL 4.1.0** - VHDL simulator
- **Python 3.10** - For cocotb and scripting
- **cocotb 1.8.1** - Python-based hardware testbench framework
- **Make** - Build automation
- **GTKWave** - Waveform viewer (optional)

## Environment Variables

When using `docker-run.sh`, pass additional Docker options via `DOCKER_OPTS`:

```bash
# Example: pass environment variables
DOCKER_OPTS="-e DEBUG=1" ./docker-run.sh make test

# Example: map additional volumes
DOCKER_OPTS="-v /extra/path:/data" ./docker-run.sh bash
```

## Benefits

✅ **Consistency** - Same GHDL version everywhere (local, CI, team)
✅ **No Installation** - GHDL and cocotb come pre-installed
✅ **Isolation** - Doesn't affect system packages
✅ **Reproducibility** - Exact same environment for all users
✅ **CI/CD Ready** - Automatic image builds and pushes to ghcr.io

## Troubleshooting

### Image build fails
```bash
# Clean and rebuild
docker system prune -a
./docker-run.sh make clean
./docker-run.sh bash
```

### Permission issues
Make sure Docker daemon is running:
```bash
sudo systemctl start docker
```

### Large image size
The image is ~2GB (includes LLVM-based GHDL). For CI, GitHub Actions caches layers automatically.

## Further Reading

- [GHDL Documentation](https://ghdl.readthedocs.io/)
- [cocotb Documentation](https://docs.cocotb.org/)
- [Docker Documentation](https://docs.docker.com/)
