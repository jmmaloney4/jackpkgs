self: super: {
  tod = self.callPackage ../pkgs/tod { };  # callPackage relative to overlay file
}
