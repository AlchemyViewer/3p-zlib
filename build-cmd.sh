#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# bleat on references to undefined shell variables
set -u

ZLIB_SOURCE_DIR="zlib"

top="$(pwd)"
stage="$top"/stage

# load autobuild provided shell functions and variables
case "$AUTOBUILD_PLATFORM" in
    windows*)
        autobuild="$(cygpath -u "$AUTOBUILD")"
    ;;
    *)
        autobuild="$AUTOBUILD"
    ;;
esac
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

VERSION_HEADER_FILE="$ZLIB_SOURCE_DIR/zlib.h"
version=$(sed -n -E 's/#define ZLIB_VERSION "([0-9.]+)"/\1/p' "${VERSION_HEADER_FILE}")
build=${AUTOBUILD_BUILD_ID:=0}
echo "${version}.${build}" > "${stage}/VERSION.txt"

pushd "$ZLIB_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        # ------------------------ windows, windows64 ------------------------
        windows*)
            load_vsvars

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                archflags="/arch:SSE2"
            else
                archflags=""
            fi

            mkdir -p "$stage/include/zlib"
            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            mkdir -p "build_debug"
            pushd "build_debug"
                # Invoke cmake and use as official build
                cmake -E env CFLAGS="$archflags" CXXFLAGS="$archflags /std:c++17 /permissive-" LDFLAGS="/DEBUG:FULL" \
                cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -T host="$AUTOBUILD_WIN_VSHOST" .. -DBUILD_SHARED_LIBS=ON

                cmake --build . --config Debug --clean-first

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Debug
                fi

                cp -a "Debug/zlibd1.dll" "$stage/lib/debug/"
                cp -a "Debug/zlibd.lib" "$stage/lib/debug/"
                cp -a "Debug/zlibd.exp" "$stage/lib/debug/"
                cp -a "Debug/zlibd.pdb" "$stage/lib/debug/"
                cp -a "Debug/minizipd.dll" "$stage/lib/debug/"
                cp -a "Debug/minizipd.lib" "$stage/lib/debug/"
                cp -a "Debug/minizipd.exp" "$stage/lib/debug/"
                cp -a "Debug/minizipd.pdb" "$stage/lib/debug/"
                cp -a zconf.h "$stage/include/zlib"
            popd

            mkdir -p "build_release"
            pushd "build_release"
                # Invoke cmake and use as official build
                cmake -E env CFLAGS="$archflags /Ob3 /GL /Gy /Zi" CXXFLAGS="$archflags /Ob3 /GL /Gy /Zi /std:c++17 /permissive-" LDFLAGS="/LTCG /OPT:REF /OPT:ICF /DEBUG:FULL" \
                cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -T host="$AUTOBUILD_WIN_VSHOST" .. -DBUILD_SHARED_LIBS=ON

                cmake --build . --config Release --clean-first

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                cp -a "Release/zlib1.dll" "$stage/lib/release/"
                cp -a "Release/zlib.lib" "$stage/lib/release/"
                cp -a "Release/zlib.exp" "$stage/lib/release/"
                cp -a "Release/zlib.pdb" "$stage/lib/release/"
                cp -a "Release/minizip.dll" "$stage/lib/release/"
                cp -a "Release/minizip.lib" "$stage/lib/release/"
                cp -a "Release/minizip.exp" "$stage/lib/release/"
                cp -a "Release/minizip.pdb" "$stage/lib/release/"
                cp -a zconf.h "$stage/include/zlib"
            popd
            cp -a zlib.h "$stage/include/zlib"
        ;;

        # ------------------------- darwin, darwin64 -------------------------
        darwin*)
            case "$AUTOBUILD_ADDRSIZE" in
                32)
                    cfg_sw=
                    ;;
                64)
                    cfg_sw="--64"
                    ;;
            esac

            # Install name for dylibs based on major version number
            install_name="@executable_path/../Resources/libz.1.dylib"

            cc_opts="${TARGET_OPTS:--arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE}"
            ld_opts="-Wl,-install_name,\"${install_name}\" -Wl,-headerpad_max_install_names"
            export CC=clang

            # release
            CFLAGS="$cc_opts" \
            LDFLAGS="$ld_opts" \
                ./configure $cfg_sw --prefix="$stage" --includedir="$stage/include/zlib" --libdir="$stage/lib/release"
            make
            make install
            cp -a "$top"/libz_darwin_release.exp "$stage"/lib/release/libz_darwin.exp

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                # Build a Resources directory as a peer to the test executable directory
                # and fill it with symlinks to the dylibs.  This replicates the target
                # environment of the viewer.
                mkdir -p ../Resources
                ln -sf "${stage}"/lib/release/*.dylib ../Resources

                make test

                # And wipe it
                rm -rf ../Resources
            fi

            # minizip
            pushd contrib/minizip
                CFLAGS="$cc_opts" make -f Makefile.Linden all
                cp -a libminizip.a "$stage"/lib/release/
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make -f Makefile.Linden test
                fi
                make -f Makefile.Linden clean
            popd

            make distclean
        ;;            

        # -------------------------- linux, linux64 --------------------------
        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Default target per autobuild build --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
			DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC"
			RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
			DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
			RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
			RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
			RELEASE_CPPFLAGS="-DPIC"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Fix up path for pkgconfig
            if [ -d "$stage/packages/lib/release/pkgconfig" ]; then
                fix_pkgconfig_prefix "$stage/packages"
            fi

            OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

            # Debug first
            export PKG_CONFIG_PATH="$stage/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" CPPFLAGS="$DEBUG_CPPFLAGS" \
                ./configure --static --prefix="\${AUTOBUILD_PACKAGES_DIR}" \
                    --includedir="\${prefix}/include/zlib" --libdir="\${prefix}/lib/debug"
            make
            make install DESTDIR="$stage"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            # minizip
            pushd contrib/minizip
                CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" CPPFLAGS="$DEBUG_CPPFLAGS" \
                    make -f Makefile.Linden all
                cp -a libminizip.a "$stage"/lib/debug/
                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make -f Makefile.Linden test
                fi
                make -f Makefile.Linden clean
            popd

            # clean the build artifacts
            make distclean

            # Release last
            export PKG_CONFIG_PATH="$stage/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" CPPFLAGS="$RELEASE_CPPFLAGS" \
                ./configure --static --prefix="\${AUTOBUILD_PACKAGES_DIR}" \
                    --includedir="\${prefix}/include/zlib" --libdir="\${prefix}/lib/release"
            make
            make install DESTDIR="$stage"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            # minizip
            pushd contrib/minizip
                CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" CPPFLAGS="$RELEASE_CPPFLAGS" \
                    make -f Makefile.Linden all
                cp -a libminizip.a "$stage"/lib/release/
                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make -f Makefile.Linden test
                fi
                make -f Makefile.Linden clean
            popd

            # clean the build artifacts
            make distclean
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    # The copyright info for zlib is the tail end of its README file. Tempting
    # though it is to write something like 'tail -n 31 README', that will
    # quietly fail if the length of the copyright notice ever changes.
    # Instead, look for the section header that sets off that passage and copy
    # from there through EOF. (Given that END is recognized by awk, you might
    # reasonably expect '/pattern/,END' to work, but no: END can only be used
    # to fire an action past EOF. Have to simulate by using another regexp we
    # hope will NOT match.)
    awk '/^Copyright notice:$/,/@%rest%@/' README > "$stage/LICENSES/zlib.txt"
    # In case the section header changes, ensure that zlib.txt is non-empty.
    # (With -e in effect, a raw test command has the force of an assert.)
    # Exiting here means we failed to match the copyright section header.
    # Check the README and adjust the awk regexp accordingly.
    [ -s "$stage/LICENSES/zlib.txt" ]
    pushd contrib/minizip
        mkdir -p "$stage"/include/minizip/
        cp -a ioapi.h zip.h unzip.h "$stage"/include/minizip/
        awk '/^License$/,/@%rest%@/' MiniZip64_info.txt > "$stage/LICENSES/minizip.txt"
        [ -s "$stage/LICENSES/minizip.txt" ]
    popd
popd

mkdir -p "$stage"/docs/zlib/
cp -a README.Linden "$stage"/docs/zlib/
