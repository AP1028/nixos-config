# Node modules for the ZCode document skills: docx-js (docx), pptxgenjs (pptx),
# playwright + pdf-lib (pdf creative route), sharp (SVG rasterization).
# Exposed via NODE_PATH; playwright browsers come from nixpkgs' playwright-driver
# (pinned to the same 1.61.x line the npm packages expect), exposed via
# PLAYWRIGHT_BROWSERS_PATH in the host config.
{
  buildNpmPackage,
  playwright-driver,
}:
buildNpmPackage {
  pname = "document-skills-node";
  version = "1.0.0";
  src = ./.;

  npmDepsHash = "sha256-kBJ0glWfOvmeW3lworVDvmK7+rxxcdfEiukzWMD2VkE=";

  dontNpmBuild = true;
  dontNpmInstall = true;

  # playwright's postinstall downloads browsers into the closure - the nixpkgs
  # playwright-driver.browsers set is linked in installPhase instead
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = 1;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/node_modules $out/share
    cp -r node_modules $out/lib/
    ln -s ${playwright-driver.browsers} $out/share/playwright-browsers
    runHook postInstall
  '';
}
