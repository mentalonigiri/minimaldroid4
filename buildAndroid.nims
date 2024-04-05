#!/bin/env -S nim e --hints:off

import os
import strutils
import strformat

# override variables from environment instead of editing the code
const
    home = getHomeDir()
    android_home = getEnv("ANDROID_HOME", home / "Android/Sdk")
    ndk_version = getEnv("ANDROID_NDK_VERSION", "26.2.11394342")
    build_for_archs = getEnv("BUILD_FOR_ARCHS", "x86_64,armeabi,armeabi-v7a,arm64-v8a").split(",")
    buildtools_version = getEnv("ANDROID_BUILDTOOLS_VERSION", "34.0.0")
    android_legacy_platform = getEnv("ANDROID_LEGACY_PLATFORM", "21")
    android_target_platform = getEnv("ANDROID_TARGET_PLATFORM", "34")
    android_host_os = getEnv("ANDROID_HOST_OS", "linux-x86_64")
    key_store = getEnv("KEY_STORE", "debug.keystore") # key store with "release" key
    ks_pass = getEnv("KS_PASS", "mypassword") # password for the key store
    key_pass = getEnv("KEY_PASS", "mypassword") # password for the key key (yes, it is)
    cmake_version = getEnv("ANDROID_CMAKE_VERSION", "3.22.1")
    ndk_root = android_home / "ndk" / ndk_version
    toolchain_path = ndk_root / "toolchains/llvm/prebuilt" / android_host_os / "bin"
    buildtools_path = android_home / "build-tools" / buildtools_version
    path = getEnv("PATH")
    needed_sdk_dirs = @[
        &"ndk/{ndk_version}",
        &"build-tools/{buildtools_version}",
        &"cmake/{cmake_version}",
        &"platform-tools",
        &"tools",
        &"platforms/android-{android_target_platform}"
    ]

# env setup
putEnv("ANDROID_HOME", android_home)
putEnv("ANDROID_SDK_ROOT", android_home)
putEnv("ANDROID_NDK_ROOT", ndk_root)

# PATH setup
putEnv("PATH", &"{toolchain_path}:{buildtools_path}:{path}")

# determine if we need to install sdk components
var want_sdk = false
for component in needed_sdk_dirs:
    if not dirExists(android_home / component):
        want_sdk = true

const
    sdkmanager_license_command = fmt"""
        sdkmanager --sdk_root="{android_home}" --licenses"""
    sdkmanager_install_command = fmt"""
            sdkmanager --sdk_root="{android_home}"
            "build-tools;{buildtools_version}"
            "cmake;{cmake_version}"
            "ndk;{ndk_version}"
            "platform-tools"
            "platforms;android-{android_target_platform}"
            "tools"
        """
        .unindent()
        .replace("\n", " ")

proc installAndroidSdk() =
    mkDir(android_home)
    exec(sdkmanager_license_command, "y\r\n".repeat(42))
    exec(sdkmanager_install_command)
    exec(sdkmanager_license_command, "y\r\n".repeat(42))

# install sdk if needed
if want_sdk:
   installAndroidSdk()


for arch in build_for_archs:
    exec(&"xmake f --ndk_sdkver={android_legacy_platform} -y -p android -m release -a {arch}")
    exec("xmake build -y jni-main")
    mkDir(&"build/apk/lib/{arch}")
    for path in walkDirRec(&"build/android/{arch}"):
        if path.endsWith(".so"):
            let destPath = &"build/apk/lib/{arch}/{extractFilename(path)}"
            cpFile(path, destPath)
    var (libpath, exitCode) = gorgeEx(&"""xrepo env nim --hints:off --eval:'echo getEnv("LIBRARY_PATH")'""")
    var pathdirs = libpath.split(":")
    for pathdir in pathdirs:
        if dirExists(pathdir) and ("packages/" in pathdir):
            for path in walkDirRec(pathdir):
                if path.endsWith(".so"):
                    let destPath = &"build/apk/lib/{arch}/{extractFilename(path)}"
                    cpFile(path, destPath)

exec(&"""aapt package -f -M AndroidManifest.xml -I {android_home}/platforms/android-{android_target_platform}/android.jar -S res -F apk-unaligned.apk build/apk""")

exec("zipalign -f 4 apk-unaligned.apk apk-unsigned.apk")

if (key_store == "debug.keystore"):
    rmFile("debug.keystore")
    exec(&"""keytool -genkey -v -keystore debug.keystore -alias debug -keyalg RSA -keysize 2048 -validity 10000 -storepass "{ks_pass}" -keypass "{key_pass}" -dname "CN=John Doe, OU=Mobile Development, O=My Company, L=New York, ST=NY, C=US" -noprompt""")

exec(&"""apksigner sign --ks {key_store} --ks-pass pass:{ks_pass} --key-pass pass:{key_pass} --out app.apk apk-unsigned.apk""")

rmFile("apk-unsigned.apk")
rmFile("apk-unaligned.apk")
rmFile("app.apk.idsig")
rmFile("debug.keystore")
rmDir("build")
rmDir(".xmake")
