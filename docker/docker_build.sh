#!/usr/bin/env bash
#
# docker_build.sh is used to build Open3D docker images for all supported
# scenarios. This can be used in CI and on local machines. The objective is to
# allow developers to emulate CI environments for debugging or build release
# artifacts such as Python wheels locally.
#
# Guidelines:
# - Use a flat list of options.
#   We don't want to have a cartesian product of different combinations of
#   options. E.g., to support Ubuntu {18.04, 20.04} with Python {3.7, 3.8}, we
#   don't specify the OS and Python version separately, instead, we have a flat
#   list of combinations: [u1804_py37, u1804_py38, u2004_py37, u2004_py38].
# - No external environment variables.
#   This script should not make assumptions on external environment variables.
#   This make the Docker image reproducible across different machines.
set -euo pipefail

__usage_docker_build="USAGE:
    $(basename $0) [OPTION]

OPTION:
    # OpenBLAS AMD64 (Dockerfile.openblas)
    openblas-amd64-py36-dev   : OpenBLAS AMD64 3.6 wheel, developer mode
    openblas-amd64-py37-dev   : OpenBLAS AMD64 3.7 wheel, developer mode
    openblas-amd64-py38-dev   : OpenBLAS AMD64 3.8 wheel, developer mode
    openblas-amd64-py39-dev   : OpenBLAS AMD64 3.9 wheel, developer mode
    openblas-amd64-py36       : OpenBLAS AMD64 3.6 wheel, release mode
    openblas-amd64-py37       : OpenBLAS AMD64 3.7 wheel, release mode
    openblas-amd64-py38       : OpenBLAS AMD64 3.8 wheel, release mode
    openblas-amd64-py39       : OpenBLAS AMD64 3.9 wheel, release mode

    # OpenBLAS ARM64 (Dockerfile.openblas)
    openblas-arm64-py36-dev   : OpenBLAS ARM64 3.6 wheel, developer mode
    openblas-arm64-py37-dev   : OpenBLAS ARM64 3.7 wheel, developer mode
    openblas-arm64-py38-dev   : OpenBLAS ARM64 3.8 wheel, developer mode
    openblas-arm64-py39-dev   : OpenBLAS ARM64 3.9 wheel, developer mode
    openblas-arm64-py36       : OpenBLAS ARM64 3.6 wheel, release mode
    openblas-arm64-py37       : OpenBLAS ARM64 3.7 wheel, release mode
    openblas-arm64-py38       : OpenBLAS ARM64 3.8 wheel, release mode
    openblas-arm64-py39       : OpenBLAS ARM64 3.9 wheel, release mode

    # Ubuntu CPU CI (Dockerfile.ci)
    cpu-static                : Ubuntu CPU static
    cpu-shared                : Ubuntu CPU shared
    cpu-shared-release        : Ubuntu CPU shared, release mode
    cpu-shared-ml             : Ubuntu CPU shared with ML
    cpu-shared-ml-release     : Ubuntu CPU shared with ML, release mode

    # CUDA wheels (Dockerfile.wheel)
    cuda-wheel-py36-dev       : CUDA Python 3.6 wheel, developer mode
    cuda-wheel-py37-dev       : CUDA Python 3.7 wheel, developer mode
    cuda-wheel-py38-dev       : CUDA Python 3.8 wheel, developer mode
    cuda-wheel-py39-dev       : CUDA Python 3.9 wheel, developer mode
    cuda-wheel-py36           : CUDA Python 3.6 wheel, release mode
    cuda-wheel-py37           : CUDA Python 3.7 wheel, release mode
    cuda-wheel-py38           : CUDA Python 3.8 wheel, release mode
    cuda-wheel-py39           : CUDA Python 3.9 wheel, release mode

    # CUDA CIs (Dockerfile.ci)
    cuda-ci-bionic                  : CUDA CI, no ML, static, 18.04, developer mode
    cuda-ci-ml-shared-bionic-release: CUDA CI,    ML, shared, 18.04, release mode
    cuda-ci-ml-shared-bionic        : CUDA CI,    ML, shared, 18.04, developer mode
    cuda-ci-shared-bionic           : CUDA CI, no ML, shared, 18.04, developer mode
    cuda-ci-shared-bionic-release   : CUDA CI, no ML, shared, 18.04, release mode
    cuda-ci-ml-focal                : CUDA CI,    ML, static, 20.04, developer mode
"

HOST_OPEN3D_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. >/dev/null 2>&1 && pwd)"

# Shared variables
CCACHE_VERSION=4.3
CMAKE_VERSION=cmake-3.19.7-Linux-x86_64

print_usage_and_exit_docker_build() {
    echo "$__usage_docker_build"
    exit 1
}

openblas_print_env() {
    echo "[openblas_print_env()] DOCKER_TAG: ${DOCKER_TAG}"
    echo "[openblas_print_env()] BASE_IMAGE: ${BASE_IMAGE}"
    echo "[openblas_print_env()] CMAKE_VER: ${CMAKE_VER}"
    echo "[openblas_print_env()] CCACHE_TAR_NAME: ${CCACHE_TAR_NAME}"
    echo "[openblas_print_env()] PYTHON_VERSION: ${PYTHON_VERSION}"
    echo "[openblas_print_env()] DEVELOPER_BUILD: ${DEVELOPER_BUILD}"
}

openblas_export_env() {
    options="$(echo "$@" | tr ' ' '|')"
    echo "[openblas_export_env()] options: ${options}"

    if [[ "amd64" =~ ^($options)$ ]]; then
        echo "[openblas_export_env()] platform AMD64"
        export DOCKER_TAG=open3d-ci:openblas-amd64
        export BASE_IMAGE=ubuntu:18.04
        export CMAKE_VER=cmake-3.19.7-Linux-x86_64
        export CCACHE_TAR_NAME=open3d-ci-openblas-amd64
    elif [[ "arm64" =~ ^($options)$ ]]; then
        echo "[openblas_export_env()] platform ARM64"
        export DOCKER_TAG=open3d-ci:openblas-arm64
        export BASE_IMAGE=arm64v8/ubuntu:18.04
        export CMAKE_VER=cmake-3.19.7-Linux-aarch64
        export CCACHE_TAR_NAME=open3d-ci-openblas-arm64
    else
        echo "Invalid platform."
        print_usage_and_exit_docker_build
    fi

    if [[ "py36" =~ ^($options)$ ]]; then
        export PYTHON_VERSION=3.6
        export DOCKER_TAG=${DOCKER_TAG}-py36
    elif [[ "py37" =~ ^($options)$ ]]; then
        export PYTHON_VERSION=3.7
        export DOCKER_TAG=${DOCKER_TAG}-py37
    elif [[ "py38" =~ ^($options)$ ]]; then
        export PYTHON_VERSION=3.8
        export DOCKER_TAG=${DOCKER_TAG}-py38
    elif [[ "py39" =~ ^($options)$ ]]; then
        export PYTHON_VERSION=3.9
        export DOCKER_TAG=${DOCKER_TAG}-py39
    else
        echo "Invalid python version."
        print_usage_and_exit_docker_build
    fi

    if [[ "dev" =~ ^($options)$ ]]; then
        export DEVELOPER_BUILD=ON
        export DOCKER_TAG=${DOCKER_TAG}-dev
    else
        export DEVELOPER_BUILD=OFF
        export DOCKER_TAG=${DOCKER_TAG}-release
    fi

    # For docker_test.sh
    export BUILD_CUDA_MODULE=OFF
    export BUILD_PYTORCH_OPS=OFF
    export BUILD_TENSORFLOW_OPS=OFF
}

openblas_build() {
    openblas_print_env

    # Docker build
    pushd "${HOST_OPEN3D_ROOT}"
    docker build --build-arg BASE_IMAGE="${BASE_IMAGE}" \
                 --build-arg CMAKE_VER="${CMAKE_VER}" \
                 --build-arg CCACHE_TAR_NAME="${CCACHE_TAR_NAME}" \
                 --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
                 --build-arg DEVELOPER_BUILD="${DEVELOPER_BUILD}" \
                 -t "${DOCKER_TAG}" \
                 -f docker/Dockerfile.openblas .
    popd

    # Extract ccache
    docker run -v "${PWD}:/opt/mount" --rm "${DOCKER_TAG}" \
        bash -c "cp /${CCACHE_TAR_NAME}.tar.gz /opt/mount \
              && chown $(id -u):$(id -g) /opt/mount/${CCACHE_TAR_NAME}.tar.gz"

    # Extract wheels
    docker run -v "${PWD}:/opt/mount" --rm "${DOCKER_TAG}" \
        bash -c "cp /*.whl /opt/mount \
              && chown $(id -u):$(id -g) /opt/mount/*.whl"
}

cuda-wheel_build() {
    BASE_IMAGE=nvidia/cuda:11.0.3-cudnn8-devel-ubuntu18.04
    CCACHE_TAR_NAME=open3d-ubuntu-1804-cuda-ci-ccache
    CMAKE_VERSION=cmake-3.19.7-Linux-x86_64
    CCACHE_VERSION=4.3

    options="$(echo "$@" | tr ' ' '|')"
    echo "[cuda-wheel_build()] options: ${options}"
    if [[ "py36" =~ ^($options)$ ]]; then
        PYTHON_VERSION=3.6
    elif [[ "py37" =~ ^($options)$ ]]; then
        PYTHON_VERSION=3.7
    elif [[ "py38" =~ ^($options)$ ]]; then
        PYTHON_VERSION=3.8
    elif [[ "py39" =~ ^($options)$ ]]; then
        PYTHON_VERSION=3.9
    else
        echo "Invalid python version."
        print_usage_and_exit_docker_build
    fi
    if [[ "dev" =~ ^($options)$ ]]; then
        DEVELOPER_BUILD=ON
    else
        DEVELOPER_BUILD=OFF
    fi
    echo "[cuda-wheel_build()] PYTHON_VERSION: ${PYTHON_VERSION}"
    echo "[cuda-wheel_build()] DEVELOPER_BUILD: ${DEVELOPER_BUILD}"

    # Docker build
    pushd "${HOST_OPEN3D_ROOT}"
    docker build \
        --build-arg BASE_IMAGE="${BASE_IMAGE}" \
        --build-arg DEVELOPER_BUILD="${DEVELOPER_BUILD}" \
        --build-arg CCACHE_TAR_NAME="${CCACHE_TAR_NAME}" \
        --build-arg CMAKE_VERSION="${CMAKE_VERSION}" \
        --build-arg CCACHE_VERSION="${CCACHE_VERSION}" \
        --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
        -t open3d-ci:wheel \
        -f docker/Dockerfile.wheel .
    popd

    # Extract pip wheel, ccache
    python_package_dir=/root/Open3D/build/lib/python_package
    docker run -v "${PWD}:/opt/mount" --rm open3d-ci:wheel \
        bash -c "cp ${python_package_dir}/pip_package/open3d*.whl /opt/mount \
              && cp /${CCACHE_TAR_NAME}.tar.gz /opt/mount \
              && chown $(id -u):$(id -g) /opt/mount/open3d*.whl \
              && chown $(id -u):$(id -g) /opt/mount/${CCACHE_TAR_NAME}.tar.gz"
}

ci_build() {
    echo "[ci_build()] DOCKER_TAG=${DOCKER_TAG}"
    echo "[ci_build()] BASE_IMAGE=${BASE_IMAGE}"
    echo "[ci_build()] DEVELOPER_BUILD=${DEVELOPER_BUILD}"
    echo "[ci_build()] CCACHE_TAR_NAME=${CCACHE_TAR_NAME}"
    echo "[ci_build()] CMAKE_VERSION=${CMAKE_VERSION}"
    echo "[ci_build()] CCACHE_VERSION=${CCACHE_VERSION}"
    echo "[ci_build()] PYTHON_VERSION=${PYTHON_VERSION}"
    echo "[ci_build()] SHARED=${SHARED}"
    echo "[ci_build()] BUILD_CUDA_MODULE=${BUILD_CUDA_MODULE}"
    echo "[ci_build()] BUILD_TENSORFLOW_OPS=${BUILD_TENSORFLOW_OPS}"
    echo "[ci_build()] BUILD_PYTORCH_OPS=${BUILD_PYTORCH_OPS}"
    echo "[ci_build()] PACKAGE=${PACKAGE}"

    pushd "${HOST_OPEN3D_ROOT}"
    docker build \
        --build-arg BASE_IMAGE="${BASE_IMAGE}" \
        --build-arg DEVELOPER_BUILD="${DEVELOPER_BUILD}" \
        --build-arg CCACHE_TAR_NAME="${CCACHE_TAR_NAME}" \
        --build-arg CMAKE_VERSION="${CMAKE_VERSION}" \
        --build-arg CCACHE_VERSION="${CCACHE_VERSION}" \
        --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
        --build-arg SHARED="${SHARED}" \
        --build-arg BUILD_CUDA_MODULE="${BUILD_CUDA_MODULE}" \
        --build-arg BUILD_TENSORFLOW_OPS="${BUILD_TENSORFLOW_OPS}" \
        --build-arg BUILD_PYTORCH_OPS="${BUILD_PYTORCH_OPS}" \
        --build-arg PACKAGE="${PACKAGE}" \
        -t "${DOCKER_TAG}" \
        -f docker/Dockerfile.ci .
    popd

    docker run -v "${PWD}:/opt/mount" --rm "${DOCKER_TAG}" \
        bash -cx "cp /open3d*.tar* /opt/mount \
               && chown $(id -u):$(id -g) /opt/mount/open3d*.tar*"
}

cuda-ci-bionic_export_env() {
    export DOCKER_TAG=open3d-ci:cuda-ci-bionic

    export BASE_IMAGE=nvidia/cuda:11.0.3-cudnn8-devel-ubuntu18.04
    export DEVELOPER_BUILD=ON
    export CCACHE_TAR_NAME=open3d-ci-cuda-ci-bionic
    export PYTHON_VERSION=3.6
    export SHARED=OFF
    export BUILD_CUDA_MODULE=ON
    export BUILD_TENSORFLOW_OPS=OFF
    export BUILD_PYTORCH_OPS=OFF
    export PACKAGE=OFF
}

cuda-ci-ml-shared-bionic_export_env() {
    export DOCKER_TAG=open3d-ci:cuda-ci-ml-shared-bionic

    export BASE_IMAGE=nvidia/cuda:11.0.3-cudnn8-devel-ubuntu18.04
    export DEVELOPER_BUILD=ON
    export CCACHE_TAR_NAME=open3d-ci-cuda-ci-bionic
    export PYTHON_VERSION=3.6
    export SHARED=ON
    export BUILD_CUDA_MODULE=ON
    export BUILD_TENSORFLOW_OPS=ON
    export BUILD_PYTORCH_OPS=ON
    export PACKAGE=ON
}

cuda-ci-ml-shared-bionic-release_export_env() {
    export DOCKER_TAG=open3d-ci:cuda-ci-ml-shared-bionic

    export BASE_IMAGE=nvidia/cuda:11.0.3-cudnn8-devel-ubuntu18.04
    export DEVELOPER_BUILD=OFF
    export CCACHE_TAR_NAME=open3d-ci-cuda-ci-bionic
    export PYTHON_VERSION=3.6
    export SHARED=ON
    export BUILD_CUDA_MODULE=ON
    export BUILD_TENSORFLOW_OPS=ON
    export BUILD_PYTORCH_OPS=ON
    export PACKAGE=ON
}

cuda-ci-shared-bionic_export_env() {
    export DOCKER_TAG=open3d-ci:cuda-ci-shared-bionic

    export BASE_IMAGE=nvidia/cuda:11.0.3-cudnn8-devel-ubuntu18.04
    export DEVELOPER_BUILD=ON
    export CCACHE_TAR_NAME=open3d-ci-cuda-ci-bionic
    export PYTHON_VERSION=3.6
    export SHARED=ON
    export BUILD_CUDA_MODULE=ON
    export BUILD_TENSORFLOW_OPS=OFF
    export BUILD_PYTORCH_OPS=OFF
    export PACKAGE=ON
}

cuda-ci-shared-bionic-release_export_env() {
    export DOCKER_TAG=open3d-ci:cuda-ci-shared-bionic

    export BASE_IMAGE=nvidia/cuda:11.0.3-cudnn8-devel-ubuntu18.04
    export DEVELOPER_BUILD=OFF
    export CCACHE_TAR_NAME=open3d-ci-cuda-ci-bionic
    export PYTHON_VERSION=3.6
    export SHARED=ON
    export BUILD_CUDA_MODULE=ON
    export BUILD_TENSORFLOW_OPS=OFF
    export BUILD_PYTORCH_OPS=OFF
    export PACKAGE=ON
}

cuda-ci-ml-focal_export_env() {
    export DOCKER_TAG=open3d-ci:cuda-ci-ml-focal

    export BASE_IMAGE=nvidia/cuda:11.0.3-cudnn8-devel-ubuntu20.04
    export DEVELOPER_BUILD=ON
    export CCACHE_TAR_NAME=open3d-ci-cuda-ci-focal
    export PYTHON_VERSION=3.6
    export SHARED=OFF
    export BUILD_CUDA_MODULE=ON
    export BUILD_TENSORFLOW_OPS=ON
    export BUILD_PYTORCH_OPS=ON
    export PACKAGE=OFF
}

cpu-static_export_env() {
    export DOCKER_TAG=open3d-ci:cpu-static

    export BASE_IMAGE=ubuntu:18.04
    export DEVELOPER_BUILD=ON
    export CCACHE_TAR_NAME=open3d-ci-cpu
    export PYTHON_VERSION=3.6
    export SHARED=OFF
    export BUILD_CUDA_MODULE=OFF
    export BUILD_TENSORFLOW_OPS=OFF
    export BUILD_PYTORCH_OPS=OFF
    export PACKAGE=OFF
}

cpu-shared_export_env() {
    export DOCKER_TAG=open3d-ci:cpu-shared

    export BASE_IMAGE=ubuntu:18.04
    export DEVELOPER_BUILD=ON
    export CCACHE_TAR_NAME=open3d-ci-cpu
    export PYTHON_VERSION=3.6
    export SHARED=ON
    export BUILD_CUDA_MODULE=OFF
    export BUILD_TENSORFLOW_OPS=OFF
    export BUILD_PYTORCH_OPS=OFF
    export PACKAGE=ON
}

cpu-shared-ml_export_env() {
    export DOCKER_TAG=open3d-ci:cpu-shared-ml

    export BASE_IMAGE=ubuntu:18.04
    export DEVELOPER_BUILD=ON
    export CCACHE_TAR_NAME=open3d-ci-cpu
    export PYTHON_VERSION=3.6
    export SHARED=ON
    export BUILD_CUDA_MODULE=OFF
    export BUILD_TENSORFLOW_OPS=ON
    export BUILD_PYTORCH_OPS=ON
    export PACKAGE=ON
}

cpu-shared-release_export_env() {
    export DOCKER_TAG=open3d-ci:cpu-shared

    export BASE_IMAGE=ubuntu:18.04
    export DEVELOPER_BUILD=OFF
    export CCACHE_TAR_NAME=open3d-ci-cpu
    export PYTHON_VERSION=3.6
    export SHARED=ON
    export BUILD_CUDA_MODULE=OFF
    export BUILD_TENSORFLOW_OPS=OFF
    export BUILD_PYTORCH_OPS=OFF
    export PACKAGE=ON
}

cpu-shared-ml-release_export_env() {
    export DOCKER_TAG=open3d-ci:cpu-shared-ml

    export BASE_IMAGE=ubuntu:18.04
    export DEVELOPER_BUILD=OFF
    export CCACHE_TAR_NAME=open3d-ci-cpu
    export PYTHON_VERSION=3.6
    export SHARED=ON
    export BUILD_CUDA_MODULE=OFF
    export BUILD_TENSORFLOW_OPS=ON
    export BUILD_PYTORCH_OPS=ON
    export PACKAGE=ON
}

function main () {
    if [[ "$#" -ne 1 ]]; then
        echo "Error: invalid number of arguments: $#." >&2
        print_usage_and_exit_docker_build
    fi
    echo "[$(basename $0)] building $1"
    case "$1" in
        # OpenBLAS AMD64
        openblas-amd64-py36-dev)
            openblas_export_env amd64 py36 dev
            openblas_build
            ;;
        openblas-amd64-py37-dev)
            openblas_export_env amd64 py37 dev
            openblas_build
            ;;
        openblas-amd64-py38-dev)
            openblas_export_env amd64 py38 dev
            openblas_build
            ;;
        openblas-amd64-py39-dev)
            openblas_export_env amd64 py39 dev
            openblas_build
            ;;
        openblas-amd64-py36)
            openblas_export_env amd64 py36
            openblas_build
            ;;
        openblas-amd64-py37)
            openblas_export_env amd64 py37
            openblas_build
            ;;
        openblas-amd64-py38)
            openblas_export_env amd64 py38
            openblas_build
            ;;
        openblas-amd64-py39)
            openblas_export_env amd64 py39
            openblas_build
            ;;

        # OpenBLAS ARM64
        openblas-arm64-py36-dev)
            openblas_export_env arm64 py36 dev
            openblas_build
            ;;
        openblas-arm64-py37-dev)
            openblas_export_env arm64 py37 dev
            openblas_build
            ;;
        openblas-arm64-py38-dev)
            openblas_export_env arm64 py38 dev
            openblas_build
            ;;
        openblas-arm64-py39-dev)
            openblas_export_env arm64 py39 dev
            openblas_build
            ;;
        openblas-arm64-py36)
            openblas_export_env arm64 py36
            openblas_build
            ;;
        openblas-arm64-py37)
            openblas_export_env arm64 py37
            openblas_build
            ;;
        openblas-arm64-py38)
            openblas_export_env arm64 py38
            openblas_build
            ;;
        openblas-arm64-py39)
            openblas_export_env arm64 py39
            openblas_build
            ;;

        # CPU CI
        cpu-static)
            cpu-static_export_env
            ci_build
            ;;
        cpu-shared)
            cpu-shared_export_env
            ci_build
            ;;
        cpu-shared-release)
            cpu-shared-release_export_env
            ci_build
            ;;
        cpu-shared-ml)
            cpu-shared-ml_export_env
            ci_build
            ;;
        cpu-shared-ml-release)
            cpu-shared-ml-release_export_env
            ci_build
            ;;

        # CUDA wheels
        cuda-wheel-py36-dev)
            cuda-wheel_build py36 dev
            ;;
        cuda-wheel-py37-dev)
            cuda-wheel_build py37 dev
            ;;
        cuda-wheel-py38-dev)
            cuda-wheel_build py38 dev
            ;;
        cuda-wheel-py39-dev)
            cuda-wheel_build py39 dev
            ;;
        cuda-wheel-py36)
            cuda-wheel_build py36
            ;;
        cuda-wheel-py37)
            cuda-wheel_build py37
            ;;
        cuda-wheel-py38)
            cuda-wheel_build py38
            ;;
        cuda-wheel-py39)
            cuda-wheel_build py39
            ;;

        # ML CIs
        cuda-ci-bionic)
            cuda-ci-bionic_export_env
            ci_build
            ;;
        cuda-ci-ml-shared-bionic-release)
            cuda-ci-ml-shared-bionic-release_export_env
            ci_build
            ;;
        cuda-ci-ml-shared-bionic)
            cuda-ci-ml-shared-bionic_export_env
            ci_build
            ;;
        cuda-ci-shared-bionic-release)
            cuda-ci-shared-bionic-release_export_env
            ci_build
            ;;
        cuda-ci-shared-bionic)
            cuda-ci-shared-bionic_export_env
            ci_build
            ;;
        cuda-ci-ml-focal)
            cuda-ci-ml-focal_export_env
            ci_build
            ;;
        *)
            echo "Error: invalid argument: ${1}." >&2
            print_usage_and_exit_docker_build
            ;;
    esac
}

# main() will be executed when ./docker_build.sh is called directly.
# main() will not be executed when ./docker_build.sh is sourced.
if [ "$0" = "$BASH_SOURCE" ] ; then
    main "$@"
fi