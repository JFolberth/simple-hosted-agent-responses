config {
  # Analyse local module calls (modules/ subdirectory).
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
