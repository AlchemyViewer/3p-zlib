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

            # This invokes cmake only to convert zconf.h.cmakein to zconf.h.
            # Without this step, multiple compiles fail for lack of zconf.h.
            cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" . -DASM686=NO -DAMD64=NO

            build_sln "contrib/vstudio/vc12/zlibvc.sln" "ReleaseWithoutAsm|$AUTOBUILD_WIN_VSPLATFORM" "zlibstat"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then bitdir=x86
            else bitdir=x64
            fi

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                build_sln "contrib/vstudio/vc12/zlibvc.sln" "ReleaseWithoutAsm|$AUTOBUILD_WIN_VSPLATFORM" "testzlib"
                ./contrib/vstudio/vc12/$bitdir/TestZlibReleaseWithoutAsm/testzlib.exe README
            fi

            # mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"
            cp -a "contrib/vstudio/vc12/$bitdir/ZlibStatReleaseWithoutAsm/zlibstat.lib" \
                "$stage/lib/release/zlib.lib"
            mkdir -p "$stage/include/zlib"
            cp -a zlib.h zconf.h "$stage/include/zlib"

            # minizip
            pushd contrib/minizip
                nmake /f Makefile.Linden.Win32.mak
                cp -a minizip.lib "$stage"/lib/release/
            popd
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
			DEBUG_CLFAGS="$DEBUG_COMMON_FLAGS"
			RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXLFAGS="$DEBUG_COMMON_FLAGS -std=c++17"
			RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPLFAGS="-DPIC"
			RELEASE_CPPFLAGS="-DPIC"

            # Handle any deliberate platform targeting
            if [ ! "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Debug first
            CFLAGS="$DEBUG_CLFAGS" CXXFLAGS="$DEBUG_CXXLFAGS" CPPFLAGS="$DEBUG_CPPLFAGS" \
                ./configure --prefix="\${AUTOBUILD_PACKAGES_DIR}" --includedir="\${prefix}/include/zlib" --libdir="\${prefix}/lib/debug"
            make
            make install DESTDIR="$stage"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            # minizip
            pushd contrib/minizip
                CFLAGS="$DEBUG_CLFAGS" CXXFLAGS="$DEBUG_CXXLFAGS" CPPFLAGS="$DEBUG_CPPLFAGS" \
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
            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" CPPFLAGS="$RELEASE_CPPFLAGS" \
                ./configure --prefix="\${AUTOBUILD_PACKAGES_DIR}" --includedir="\${prefix}/include/zlib" --libdir="\${prefix}/lib/release"
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
