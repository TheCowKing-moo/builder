with import <nixpkgs> {};
with stdenv;

rec {
  mkBuilder = code: writeTextFile {
    name = "builder.sh";
    text = "source $stdenv/setup\n" + code;
  };

  mkServer = {
    name,
    forge,
    mods,
    screenName,
    hacks ? {},
    extraDirs ? [],
    configPatches ? [],
  }: mkDerivation (rec {
    inherit name screenName;

    src = ../base-server;

    modDirs = builtins.filter (m: m.side != "CLIENT" && m.side != "client") (builtins.attrValues mods);

    inherit forge;
    forgeMajor = forge.major;
    forgeMinor = forge.minor;

    baseMinecraft = mkBaseMinecraft {
      extraDirs = extraDirs;
      configPatches = map mkPatch configPatches;
    };

    buildInputs = [ rsync ];

    passthru = {
      inherit mods baseMinecraft;
    };
    

    builder = mkBuilder ''
      mkdir -p $out/mods

      rsync -a $src/ $out/
      chmod 0755 $out

      substituteAllInPlace $out/start.sh

      find $forge/ -mindepth 1 -maxdepth 1 -exec ln -s {} $out \;

      rsync -a $baseMinecraft/ $out/

      for modDir in $modDirs; do
        rsync -a $modDir/mods/ $out/mods/
      done
    '';
  } // hacks);

  mkBaseMinecraft = {
    # Directories to copy in verbatim. Well, derivations.
    extraDirs ? []

    # Config patches to apply.
   ,configPatches ? []
  }: mkDerivation {
    name = "base-minecraft";

    inherit extraDirs configPatches;

    buildInputs = [ rsync zip perl ];

    builder = mkBuilder ''
      mkdir $out

      for extraDir in $extraDirs; do
        rsync -aL $extraDir/ $out
      done

      chmod -R 0755 $out/config
      chmod -R 0755 $out/scripts

      for configPatch in $configPatches; do
        (cd $out/config/; source $configPatch)
      done
      find "$out" -print0 | \
        xargs -0r touch --no-dereference --date=1970-01-01

      # This is for the serverpack.
      cd $out
      chmod u+w .
      tmp=$(mktemp)
      echo '{' > $tmp
      for dir in *; do
        TZ=UTC find $dir -print0 | sort -z | \
          xargs -0 zip -X --latest-time -q $dir.zip
        md5=$(md5sum $dir.zip | awk '{print $1}')
        printf '%s = "%s";\n' $dir $md5 >> $tmp
      done
      echo '}' >> $tmp
      mv $tmp default.nix
    '';
  };

  mkPatch = patch:
    if builtins.isString patch then builtins.toFile "patch.sh" patch
    else abort "Structured patches are not yet implemented";

  mkMod = self: mkDerivation ({
    builder = mkBuilder ''
      mkdir -p $out/mods
      ln -s "$src" $out/mods/"$modpath"
      md5=$(md5sum "$src" | awk '{print $1}')
      cat >> $out/default.nix <<EOF
        { md5 = "$md5";
          modpath = "$modpath"; }
      EOF
    '';

    side = "BOTH";
    required = true;
    isDefault = false;
    modtype = "Regular";
    modpath = self.name + ".jar";
  } // self);

  # TODO(?): We could use install_profile to generate nix expressions and make this thing work sandboxed.
  # But, well, why?
  fetchForge = { major, minor }: mkDerivation rec {
    name = "forge-${major}-${minor}";

    passthru = {
      inherit major minor;
    };

    url = {
      "1.7.10" = "http://files.minecraftforge.net/maven/net/minecraftforge/forge/${major}-${minor}-${major}/forge-${major}-${minor}-${major}-installer.jar";
      "1.10.2" = "https://files.minecraftforge.net/maven/net/minecraftforge/forge/${major}-${minor}/forge-${major}-${minor}-installer.jar";
    }.${major};

    # The installer needs web access. Since it does, let's download it w/o a hash.
    #
    # If you get an error referring to this, you're probably using a strict sandbox.
    # Disable it, or set it to 'relaxed'.
    __noChroot = 1;
    buildInputs = [ jre wget cacert ];

    builder = mkBuilder ''
      mkdir $out
      cd $out
      wget $url --ca-certificate=${cacert}/etc/ssl/certs/ca-bundle.crt
      mkdir mods
      INSTALLER=$(echo *.jar)
      java -jar $INSTALLER --installServer
      rm -r $INSTALLER mods
    '';
  };


  ## Base pack generation ##
  mkBasePack = cfg: rec {

    getDir = dir: mkDerivation {
      name = builtins.replaceStrings ["/"] ["_"] dir;
      src = cfg.src;
      inherit dir;

      builder = mkBuilder ''
        mkdir -p $out/$(dirname $dir)
        ln -s $src/$dir $out/$(dirname $dir)
      '';
    };

    baseModsNix = mkDerivation {
      name = "base-mods";
      src = cfg.src;

      buildInputs = [ perl ];

      printDerivation = builtins.toFile "printDerivation.pl" ''
        use strict;

        sub p {
          my $base = shift;
          my $version = shift;
          $base =~ s/ /_/g; 
          $base =~ s/[':;\[\]]//g;
          $base =~ s/^[0-9\._-]*//;
          $version =~ s/[\[\]() :;]/_/g;
          $version =~ s/(^[-_])|([-_]$)//g;
          print "  $base = {\n";
          print "    name = \"$base-$version\";\n";
          print "    path = \"/mods/$_\";\n";
          print "    version = \"$version\";\n";
          print "  };\n\n";
          next;
        }

        print "{\n";
        while (<>) {
          $_ =~ s/\s+$//;
          # Per-mod hacks go on top.
          # Don't think too hard about it.
          p("ASP GS Patcher", "unknown") if /^ASP +GS Patcher.jar$/;
          p($1 . "-" . $+{type}, $+{version}) if /(.*BiblioWoods)\[(?<type>[^\]]+)\]\[v(?<version>[^\]]+)\].jar/;
          p($1, $+{version}) if /(.*BiblioCraft)\[v(?<version>[^\]]+)\]\[MC(?<mcversion>[^\]]+)\].jar/;
          p("ProjectRed" . $2, $1) if /ProjectRed-([0-9].*)-(.*).jar/;
          p($1, $2) if /(Steves.*?)([0-9A-Z][0-9\.].*).jar/;
          p($1, $2) if /^(Carpenters.Blocks).v([0-9.]+).-.MC.*.jar/;
          p($1, $2) if /^(Carpenter's.Blocks).v([0-9.]+).-.MC.*.jar/;
          p($1, $2) if /^(Carpenter's.Blocks).v([0-9.]+_dev_r[0-9]+).-.MC.*.jar/;
          p($1, $2) if /^(ComputerCraft)([0-9.]+).jar/;
          p($1, $2) if /^\[1.7.10\]\[[0-9.]+\+?\](TFC-Additions)-([0-9.]+).jar/;
          p($1, $2) if /^(LycanitesMobs.*) ([0-9.]+) \[1.7.10\].jar/;
          p($1, $2) if /^(DummyCore)([0-9.]+)\.jar/;
          p($1, $2) if /^(EssentialCraft)v([0-9.]+)\.jar/;
          p($1, $2) if /^(MrCrayfish[^0-9]+)v([0-9.]+)\(1.7.10\).jar/;
          p($1, $2) if /^(\w+) 1.7.10 V([0-9\w]+).jar/;
          # Some people like to put the minecraft version number first.
          p($1, $2) if /^(?:client-)?\[?1.7.10\]?-?([\w]+)-(.*).jar/;
          # Sometimes there just isn't a version number.
          p($1, "unknown") if /^([-a-zA-Z_]+).jar$/;
          # This one works on the 98% of mods remaining.
          p($1, $2) if /(?:client-)?(.*?)[-_ ]((mc|MC|rv|r|v|\[)?[0-9].*).jar/;
          print "ERROR: Couldn't parse " . $_ . "\n";
        }
        print "}\n";
      '';

      builder = mkBuilder ''
        find $src/mods -mindepth 1 -maxdepth 1 -name \*.jar -printf "%f\n" \
          | sort -f \
          | perl $printDerivation \
          > $out
        grep ^ERROR: $out && exit 1 || true
      '';
    };

    mods = lib.mapAttrs splitMod (import baseModsNix);

    splitMod = name: mod: mkMod ((cfg.modConfig.${name} or {}) // {
      name = mod.name;
      src = cfg.src + mod.path;
      modpath = builtins.baseNameOf mod.path;
    });
  };

  addManifests = manifests: concatSets (map addManifest manifests);
  addManifest = manifest: lib.mapAttrs addManifestMod (
    lib.filterAttrs (n: v: v.type != "missing")
                    (import manifest));

  addManifestMod = name: {
    title, version, src, md5,
    side ? "BOTH",
    required ? true,
    isDefault ? false,
    ...
  }: mkMod {
    name = "${name}-${version}";
    src = fetchurl {
      url = src;
      inherit md5;
    };
    inherit side required isDefault;
  };

  ## Curse-based base pack generation ##
  mkCursePack = {
    manifest, updates, modConfig ? {}
  }: rec {
    pack = mkDerivation {
      name = "modpack";
      buildInputs = [ unzip rsync ];
      inherit manifest updatedMods;
      builder = mkBuilder ''
        unzip "$manifest"
        mkdir $out
        rsync -r overrides/ $out/
        for mod in $updatedMods; do
          find $mod -mindepth 1 -maxdepth 1 -exec ln -s {} $out/mods/ \;
        done
        ls $out/mods/
      '';
    };
    updatedMods = map updatedMod (builtins.concatLists (map import updates));
    updatedMod = { name, url, md5, filename }: mkDerivation {
      inherit name filename;
      src = fetchurl { inherit url md5; };
      builder = mkBuilder ''
        mkdir $out
        ln -s "$src" "$out"/"$filename"
      '';
    };
  };

  ## Modifies Bibliocraft to add paintings, yay!
  bibliocraftWithPaintings = {
    bibliocraft,
    paintings,
  }: mkMod {
    name = bibliocraft.name + "-tampered";
    src = mkDerivation {
        name = "BiblioCraft-tampered-jar";

        src = bibliocraft;

        buildInputs = [ zip imagemagick ];
        inherit paintings;

        builder = mkBuilder ''
          cp "$(find $src -name \*.jar)" tmp.zip &
          mkdir -p assets/bibliocraft/textures/custompaintings
          pushd assets/bibliocraft/textures/custompaintings
          for i in $(find $paintings -type f); do
            convert $i -resize '512x512>' $(echo $(basename $i) | sed 's/\..*//').png &
          done
          wait
          popd
          chmod u+w tmp.zip
          zip -r tmp.zip assets
          mv tmp.zip $out
        '';
      };
  };

  # Removes a subtree of a zip. Such as APIs.
  removeAPI = { mod, path }: mkMod {
    name = mod.name + "-tampered";
    src = mkDerivation {
      name = mod.name + "-tampered-jar";
      src = mod;
      buildInputs = [ zip ];
      inherit path;
      builder = mkBuilder ''
        cp "$(find $src -name \*.jar)" tmp.zip
        chmod u+w tmp.zip
        zip -d tmp.zip $path/\*
        mv tmp.zip $out
      '';
    };
  };

  ## Server-pack builder:

  serverParams = {
    serverId,
    serverDesc,
    server,
    port,
    packUrlBase,
    hacks ? {},
  }: let
    serverUrlBase = packUrlBase + "/packs/" + serverId;
    forgeMajor = server.forge.major;
    forgeMinor = server.forge.minor;
  in {
    serverId = serverId;
    serverDesc = serverDesc;
    serverAddress = "madoka.brage.info:" + toString port;
    minecraftVersion = forgeMajor;
    forgeUrl = "https://files.mcupdater.com/example/forge.php?mc=${forgeMajor}&forge=${forgeMinor}";
    mods = lib.mapAttrs (name: mod: let details = import mod; in {
      modId = name;
      url = serverUrlBase + "/mods/" + builtins.baseNameOf mod.outPath;
      modpath = "mods/" + details.modpath;
      side = mod.side;
      required = mod.required;
      isDefault = mod.isDefault;
      modtype = mod.modtype;
      md5 = details.md5;
    }) server.mods;
    configs = lib.mapAttrs (name: md5: {
      configId = name;
      url = serverUrlBase + "/configs/" + name + ".zip";
      inherit md5;
    }) (import server.baseMinecraft);
  };

  mkServerPackDir = {
    serverId,
    serverDesc,
    server,
    port,
    hacks ? {},
  }: mkDerivation rec {
    name = serverId + "-packdir";

    modList = builtins.attrValues server.mods;
    configs = server.baseMinecraft;
    inherit serverId;

    builder = mkBuilder ''
      mkdir -p $out/$serverId/{mods,configs}
      
      for mod in $modList; do
        ln -s $mod/mods/*.jar $out/$serverId/mods/$(basename $mod)
      done

      ln -s $configs/*.zip $out/$serverId/configs/
    '';
  };

  mkServerPack = {
    servers,
    packUrlBase ? "https://madoka.brage.info/pack"
  }:  mkDerivation rec {
    name = "ServerPack";

    buildInputs = [ saxonb ];

    stylesheet = ./serverpack.xsl;

    paramsText = let
      params = lib.mapAttrs (name: desc: serverParams (desc // { inherit packUrlBase; })) servers;
      paramsWRevision = lib.mapAttrs (name: desc: desc // {
        revision = builtins.hashString "sha256" (builtins.toXML desc);
      }) params;
    in writeTextFile {
      name = "params.xml";
      text = builtins.toXML paramsWRevision;
    };
    
    packDirs = builtins.map mkServerPackDir (builtins.attrValues servers);

    builder = mkBuilder ''
      mkdir -p $out/packs
      saxon8 $paramsText ${stylesheet} > $out/ServerPack.xml

      for pack in $packDirs; do
        ln -s $pack/* $out/packs/
      done
    '';
  };


  /**
   * Concatenates a list of sets.
   */
  concatSets = builtins.foldl' (a: b: a // b) {};
  
  /**
   * Runs a command. Locally.
   */
  runLocally = name: env: cmd: lib.runCommand name ({
    preferLocalBuild = true;
    allowSubstitutes = false;
  } // env) cmd;
}
