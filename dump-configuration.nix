let
  network = (import ../nixops-deployment/mf.nix);
  nixpkgs = (import ../nixpkgs/default.nix {});
  evalConfig = (import "${nixpkgs.path}/nixos/lib/eval-config.nix");
  nixops = let
    src = fetchTarball https://github.com/NixOS/nixops/archive/dcafae5258773dc0fbdd31b425f1ad3fb59173fe.tar.gz;
  in {
    imports = [ "${src}/nix/options.nix" "${src}/nix/resource.nix" ];
  };

  dontRecursePaths = {
    startingWith = [
      ["mayflower" "machines"]
    ];
    intersectingWith = [
      # TODO: is vmVariant[WithBootLoader] of interest? If so, how to prevent recursion?
      ["virtualisation" "vmVariant"]
      ["virtualisation" "vmVariantWithBootLoader"]
    ];
  };

  dontEvaluatePaths = {
    intersectingWith = [
      # error: attribute 'kernelConfig' missing
      #
      #   at ./nixpkgs/nixos/modules/system/boot/systemd.nix:568:39:
      #
      #   567|
      #   568|     system.requiredKernelConfig = map config.lib.kernelConfig.isEnabled
      #      |                                       ^
      #   569|       [ "DEVTMPFS" "CGROUPS" "INOTIFY_USER" "SIGNALFD" "TIMERFD"
      ["containers" "config" "system" "requiredKernelConfig"]
      #error: attribute 'gitlab' missing
      #
      #       at /nix/store/rhkjd6y5pw7svqljxgxgz3p603qvqq9s-nixpkgs/nixos/modules/services/misc/gitlab.nix:473:49:
      #
      #          472|         type = types.str;
      #          473|         default = "redis://localhost:${toString config.services.redis.servers.gitlab.port}/";
      #             |                                                 ^
      #          474|         defaultText = literalExpression ''redis://localhost:''${toString config.services.redis.servers.gitlab.port}/'';
      #["containers" "config" "services" "gitlab"]
    ];
  };

  inherit (builtins)
  all any
  attrNames getAttr hasAttr
  concatStringsSep
  filter elem elemAt
  head length tail
  isAttrs isBool isFloat isFunction isInt isList isNull isString
  match
  seq
  split
  sub
  tryEval trace toString;

  inherit (nixpkgs) lib;

  inherit (lib) types;
  inherit (lib.attrsets) attrByPath filterAttrs isDerivation mapAttrs;
  inherit (lib.lists) flatten intersectLists reverseList take;
  inherit (lib.options) scrubOptionValue;
  inherit (lib.strings) isCoercibleToString;
  inherit (lib.trivial) id;

  moduleAttrsFilter = name: _: (! elem name ["defaults" "network"]);
  machines = scrubOptionValue (
    mapAttrs evaluateMachine (filterAttrs moduleAttrsFilter network)
  );
  resources = { machines = mapAttrs (name: value: value.config) machines; };

  evaluateMachine = name: machine: (
    evalConfig {
      modules = [
        {
          config.nixpkgs.config.allowUnfree = true;
          config._module.check = false;
          config._module.args = { inherit name resources; };
        }
        nixops
        network.defaults
        machine
      ];
    }
  );

  safeEval = fallback: expr: let
    result = tryEval (expr);
  in (if result.success then result.value else fallback);

  skip = count: list: (
    if (any id [(0 == count) (0 == length list)])
    then list
    else skip (count - 1) (tail list)
  );

  getByPath = path: attrByPath path null machines;

  splicePath = path: offset: deleteCount: insertList: (
    (take offset path) ++ insertList ++ (skip (offset + deleteCount) path)
  );

  resolveRenamedOption = path: let
    subpath = skip 2 path;
    isContainer = all id [
      (3 <= length subpath)
      ("containers" == elemAt subpath 0)
      ("config" == elemAt subpath 2)
    ];
    containerPath = if isContainer then take 3 subpath else [];
    lookupPath = if isContainer then skip 3 subpath else subpath;
    optionsPath = splicePath path 1 (1 + length subpath) (["options"] ++ lookupPath);
    originalOption = getByPath optionsPath;
    originalDescription = originalOption.description or "";
    matchedAlias = match "Alias of <option>(.*)</option>." originalDescription;
    matchedAliasPath = filter isString (split "\\." (head matchedAlias));
    aliasPath = containerPath ++ matchedAliasPath;
    aliasConditions = all id [
      ("option" == originalOption._type or false)
      (false == originalOption.visible or true)
      (! isNull matchedAlias)
    ];
    resolved = if aliasConditions then aliasPath else subpath;
  in splicePath path 2 (length subpath) resolved;

  logModuleDeep = path: (
    let
      resolvedPath = resolveRenamedOption path;
      conditionPath = skip 2 resolvedPath;
      optionsPath = splicePath resolvedPath 1 1 ["options"];

      isDisabled = let
        enable = getByPath (optionsPath ++ ["enable"]);
      in all id [
        ("option" == enable._type or null)
        (isBool enable.value or null)
        (false == enable.value or null)
      ];

      config = getByPath resolvedPath;

      traceout = value: let x = { inherit path value; }; in trace x x;
      output = value: { inherit path value; };

      pathIntersectingWith = p: p == intersectLists conditionPath p;
      pathStartingWith = p: p == take (length p) conditionPath;
      pathEndingWith = p: p == reverseList (take (length p) (reverseList conditionPath));

      recurseConditions = evaluateConditions && all id [
        (isAttrs config)
        (! isDerivation config)
        # error: attribute 'gitlab' missing and many more quirky behaviour
        (if isBool (config.enable or true) then config.enable or true else true)
        (! (any pathStartingWith dontRecursePaths.startingWith))
        (! (any pathIntersectingWith dontRecursePaths.intersectingWith))
      ];
      evaluateConditions = all id [
        (! isDisabled)
        (! (any pathIntersectingWith dontEvaluatePaths.intersectingWith))
      ];
      recurseForName = name: logModuleDeep (resolvedPath ++ [name]);
    in
    if safeEval false recurseConditions
    then flatten (map recurseForName (attrNames config))
    else
    if safeEval false (evaluateConditions && isDerivation config)
    then traceout (safeEval "<drvPath>" config)
    else
    if safeEval false (evaluateConditions && isCoercibleToString config)
    then traceout (safeEval "<config>" config)
    else null
  );
  notNullList = filter (a: ! isNull a);
  ignoreList = [
  ];
in
{
  inherit machines;
  names = (attrNames machines);
  clean = notNullList (
    flatten (
      map (
        name: logModuleDeep [name "config"]
      ) (
        (filter (n: (! elem n ignoreList)) (attrNames machines))
      )
    )
  );
}
