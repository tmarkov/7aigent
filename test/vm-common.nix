{ pkgs }:
{
  mkNode =
    { systemPackages ? []
    , environmentVariables ? {}
    }:
    { ... }:
    {
      boot.loader.grub.enable = false;
      virtualisation = {
        cores = 4;
        memorySize = 4096;
        graphics = false;
      };
      environment.systemPackages = systemPackages;
      environment.variables = environmentVariables;
    };

  prepareWorkspaceCommand =
    { testCodebase
    , destination
    }:
    "cp -r ${testCodebase} ${destination}"
    + " && chmod -R u+w ${destination}"
    + " && mkdir -p ${destination}/.7aigent/state";
}
