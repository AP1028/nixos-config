{ lib, stdenv, fetchurl, fetchFromGitHub, wrapGAppsHook3, libGLU, zlib, cmake, ninja, python312, rocksdb }:

let
  py = python312.pkgs;
  np = py.numpy_1;

  amulet-faulthandler = py.buildPythonPackage rec {
    pname = "amulet-faulthandler";
    version = "1.0.7";
    pyproject = true;
    src = fetchFromGitHub {
      owner = "Amulet-Team";
      repo = "Amulet-Fault-Handler";
      tag = version;
      hash = "sha256-DuF8r8NlAybvIO6iOfJl2FNRtWs0LW+EyKHVBYoL8ag=";
    };
    build-system = with py; [ setuptools wheel versioneer pybind11 ];
    nativeBuildInputs = [ cmake ninja ];
    dontUseCmakeConfigure = true;
    pythonImportsCheck = [ "amulet_faulthandler" ];
    meta = {
      description = "Python fault handler for Amulet applications";
      homepage = "https://github.com/Amulet-Team/Amulet-Fault-Handler";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  amulet-mutf8 = py.buildPythonPackage rec {
    pname = "amulet-mutf8";
    version = "1.0.7";
    format = "setuptools";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/30/0c/b49bed3ea8ccfc9956d76c422d31ba1bfaf4a0320e6ea9e02dac91f64869/amulet_mutf8-1.0.7.tar.gz";
      hash = "sha256-fkWxvf3DPjvNjphpVt56WkBKYxk3/7Rbh8aGthYUv38=";
    };
    nativeBuildInputs = with py; [ setuptools ];
    meta = {
      description = "Mojang's MUTF-8 encoding/decoding library";
      homepage = "https://github.com/Amulet-Team/mutf8";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  amulet-nbt = py.buildPythonPackage rec {
    pname = "amulet-nbt";
    version = "2.1.8";
    pyproject = true;
    src = fetchFromGitHub {
      owner = "Amulet-Team";
      repo = "Amulet-NBT";
      tag = version;
      hash = "sha256-wTfheiGD/TkzQTug1SQNu5dJNm++odmi9pz3B8kIHBA=";
    };
    build-system = with py; [ setuptools wheel cython versioneer np ];
    dependencies = with py; [ amulet-mutf8 ];
    pythonImportsCheck = [ "amulet_nbt" ];
    meta = {
      description = "Python library for reading and writing binary NBT and stringified NBT";
      homepage = "https://github.com/Amulet-Team/Amulet-NBT";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  amulet-leveldb = py.buildPythonPackage rec {
    pname = "amulet-leveldb";
    version = "1.0.7";
    pyproject = true;
    src = fetchFromGitHub {
      owner = "Amulet-Team";
      repo = "Amulet-LevelDB";
      tag = version;
      hash = "sha256-c5MvT0QU9XZgo1sGLZA8l8mfhPoNhYelDk7IkBdZFzo=";
      fetchSubmodules = true;
      postFetch = ''
        rm -r $out/zlib
      '';
    };
    postPatch = ''
      substituteInPlace setup.py \
        --replace-fail "versioneer.get_version()" "'${version}'"
    '';
    build-system = with py; [ setuptools wheel cython versioneer ];
    buildInputs = [ zlib ];
    pythonImportsCheck = [ "leveldb" ];
    meta = {
      description = "Cython wrapper for Mojang's custom LevelDB";
      homepage = "https://github.com/Amulet-Team/Amulet-LevelDB";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  amulet-pybind11-extensions = py.buildPythonPackage rec {
    pname = "amulet-pybind11-extensions";
    version = "1.2.0a2";
    format = "setuptools";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/e0/e5/b98691942aea88b8c22ecd8d916392ec65af43dbc81a4a23ab4d5eaab76f/amulet_pybind11_extensions-1.2.0a2.tar.gz";
      hash = "sha256-LQXwqdNq7u9fNhZhe7os8TgCh+rj1/AhNpcaq1dTciU=";
    };
    nativeBuildInputs = with py; [ setuptools versioneer pybind11 cmake ninja ];
    dontUseCmakeConfigure = true;
    pythonImportsCheck = [ "amulet.pybind11_extensions" ];
    meta = {
      description = "Amulet's pybind11 extensions CMake package";
      homepage = "https://github.com/Amulet-Team/Amulet-pybind11-extensions";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  amulet-rocksdb = py.buildPythonPackage rec {
    pname = "amulet-rocksdb";
    version = "1.0.5";
    format = "setuptools";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/69/15/5910d03d8c105ad8bedcba5856e1f0fadd18efafc1775fce0b299e90c372/amulet_rocksdb-1.0.5.tar.gz";
      hash = "sha256-hpaB5NGQfeC/4W3T7inx/sZQGr6GUnCRF/ocA8AYXu0=";
    };

    zstdZ = fetchurl {
      url = "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz";
      hash = "sha256-6zPlH0mhXgI5UM14Jcp0pKK0Pbg1SCWsJPwbfuCeb6M=";
    };

    rocksdbZ = fetchFromGitHub {
      owner = "Amulet-Team";
      repo = "rocksdb";
      rev = "4153aebf840920ce41dbc47896febbd3020b9d5f";
      hash = "sha256-ArQuY4s7tWXYufr1Q1zhu6pgHRu8m3a0hOobObL+oOw=";
    };

    postPatch = ''
      tar xzf ${zstdZ} -C /tmp
      substituteInPlace setup.py \
        --replace-fail '"-B",' '"-DFETCHCONTENT_SOURCE_DIR_ZSTD=/tmp/zstd-1.5.7", "-DFETCHCONTENT_SOURCE_DIR_ROCKSDB=${rocksdbZ}", "-B",'
    '';

    nativeBuildInputs = with py; [
      setuptools versioneer pybind11 cmake ninja amulet-pybind11-extensions
    ];
    buildInputs = [ rocksdb ];
    dontUseCmakeConfigure = true;
    pythonImportsCheck = [ "rocksdb" ];
    meta = {
      description = "Pybind11 wrapper for Facebook's RocksDB";
      homepage = "https://github.com/Amulet-Team/Amulet-RocksDB";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  pymctranslate = py.buildPythonPackage rec {
    pname = "pymctranslate";
    version = "1.2.46";
    pyproject = true;
    src = fetchFromGitHub {
      owner = "gentlegiantJGC";
      repo = "PyMCTranslate";
      tag = version;
      hash = "sha256-dZj1V5G+/GJm6l4M3UbzVUUaSnEFYpSb0dG8Cagxg2c=";
    };
    build-system = with py; [ setuptools wheel versioneer ];
    dependencies = with py; [ np amulet-nbt ];
    pythonImportsCheck = [ "PyMCTranslate" ];
    meta = {
      description = "Minecraft data translation system";
      homepage = "https://github.com/gentlegiantJGC/PyMCTranslate";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  minecraft-resource-pack = py.buildPythonPackage rec {
    pname = "minecraft-resource-pack";
    version = "1.4.11";
    pyproject = true;
    src = fetchFromGitHub {
      owner = "Amulet-Team";
      repo = "Minecraft-Model-Reader";
      tag = version;
      hash = "sha256-Cp+Tf9URiLMQzX4RzIjJXhy269ZAdFkDNMkRvhcIK8Y=";
    };
    build-system = with py; [ setuptools wheel versioneer ];
    dependencies = with py; [ pillow np amulet-nbt platformdirs ];
    pythonRelaxDeps = [ "platformdirs" ];
    pythonImportsCheck = [ "minecraft_model_reader" ];
    doCheck = false;
    meta = {
      description = "Load block models from Minecraft resource packs";
      homepage = "https://github.com/Amulet-Team/Minecraft-Model-Reader";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

  amulet-core = py.buildPythonPackage rec {
    pname = "amulet-core";
    version = "1.9.43";
    pyproject = true;
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/e7/2a/1d71910f341651793937c2bdf65c77c39643d9eccac6fe971a252914baf9/amulet_core-1.9.43.tar.gz";
      hash = "sha256-3Yq7SAfRZ00pV/NBfjGvGtWbjcwuFG7x606zscYXueM=";
    };
    build-system = with py; [ setuptools wheel cython versioneer np ];
    dependencies = with py; [
      amulet-nbt amulet-leveldb pymctranslate amulet-rocksdb
      lz4 portalocker platformdirs
    ];
    pythonRelaxDeps = [ "portalocker" "platformdirs" ];
    dontCheckRuntimeDeps = true;
    pythonImportsCheck = [ "amulet" ];
    meta = {
      description = "Python library for reading and writing Minecraft save formats";
      homepage = "https://github.com/Amulet-Team/Amulet-Core";
      license = lib.licenses.unfree;
      platforms = lib.platforms.linux;
    };
  };

in py.buildPythonApplication rec {
  pname = "amulet-map-editor";
  version = "0.10.60";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "Amulet-Team";
    repo = "Amulet-Map-Editor";
    tag = version;
    hash = "sha256-1s3dS4rqEmUGDNNJEAXhEbA1F6vk47qSubbyXlYkHbg=";
  };

  postPatch = ''
    substituteInPlace setup.cfg \
      --replace-fail "wayland-lock-pointer;platform_system=='Linux'" ""
  '';

  build-system = with py; [
    setuptools wheel cython versioneer np
  ];

  dependencies = with py; [
    pillow
    (wxpython.overridePythonAttrs (_: {
      propagatedBuildInputs = [
        np
        pillow
        six
      ];
    }))
    pyopengl
    pymctranslate
    minecraft-resource-pack
    amulet-core
    amulet-nbt
    amulet-faulthandler
    platformdirs
    packaging
  ];

  pythonRelaxDeps = [ "platformdirs" ];

  nativeBuildInputs = [
    wrapGAppsHook3
    libGLU
  ];

  pythonImportsCheck = [ "amulet_map_editor" ];

  meta = {
    description = "Minecraft world editor and converter supporting all versions since Java 1.12 and Bedrock 1.7";
    homepage = "https://www.amuletmc.com";
    changelog = "https://github.com/Amulet-Team/Amulet-Map-Editor/releases/tag/${version}";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
    mainProgram = "amulet_map_editor";
  };
}
