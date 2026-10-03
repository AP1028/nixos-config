{ lib, stdenv, chipmunk, libuv, sqlite, fontconfig }:
# CMake config shims for cocos2d-x externals that nixpkgs ships without a
# CMake package config (vcpkg's ports provide these targets).
stdenv.mkDerivation {
  pname = "cocos2dx-cmake-shims";
  version = "1";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/cmake/unofficial-chipmunk $out/lib/cmake/libuv \
             $out/lib/cmake/unofficial-sqlite3 $out/lib/cmake/fontconfig

    cat > $out/lib/cmake/unofficial-chipmunk/unofficial-chipmunk-config.cmake <<'EOF'
if(NOT TARGET unofficial::chipmunk::chipmunk)
    add_library(unofficial::chipmunk::chipmunk SHARED IMPORTED)
    set_target_properties(unofficial::chipmunk::chipmunk PROPERTIES
        IMPORTED_LOCATION "${chipmunk}/lib/libchipmunk.so"
        INTERFACE_INCLUDE_DIRECTORIES "${chipmunk}/include")
endif()
set(unofficial-chipmunk_FOUND TRUE)
EOF

    cat > $out/lib/cmake/libuv/libuvConfig.cmake <<'EOF'
if(NOT TARGET libuv::uv)
    add_library(libuv::uv SHARED IMPORTED)
    set_target_properties(libuv::uv PROPERTIES
        IMPORTED_LOCATION "${libuv}/lib/libuv.so"
        INTERFACE_INCLUDE_DIRECTORIES "${libuv.dev}/include")
endif()
set(libuv_FOUND TRUE)
EOF

    cat > $out/lib/cmake/unofficial-sqlite3/unofficial-sqlite3-config.cmake <<'EOF'
if(NOT TARGET unofficial::sqlite3::sqlite3)
    add_library(unofficial::sqlite3::sqlite3 SHARED IMPORTED)
    set_target_properties(unofficial::sqlite3::sqlite3 PROPERTIES
        IMPORTED_LOCATION "${sqlite.out}/lib/libsqlite3.so"
        INTERFACE_INCLUDE_DIRECTORIES "${sqlite.dev}/include")
endif()
set(unofficial-sqlite3_FOUND TRUE)
EOF

    cat > $out/lib/cmake/fontconfig/FontconfigConfig.cmake <<'EOF'
if(NOT TARGET Fontconfig::Fontconfig)
    add_library(Fontconfig::Fontconfig SHARED IMPORTED)
    set_target_properties(Fontconfig::Fontconfig PROPERTIES
        IMPORTED_LOCATION "${fontconfig.lib}/lib/libfontconfig.so"
        INTERFACE_INCLUDE_DIRECTORIES "${fontconfig.dev}/include")
endif()
set(Fontconfig_FOUND TRUE)
EOF

    # also answer the all-lowercase config name
    cp $out/lib/cmake/fontconfig/FontconfigConfig.cmake \
       $out/lib/cmake/fontconfig/fontconfig-config.cmake

    runHook postInstall
  '';
}
