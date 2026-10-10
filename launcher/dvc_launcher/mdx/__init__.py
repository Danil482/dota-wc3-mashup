"""Dota 2 model -> Warcraft III MDX converter (pure Python, ships in the exe).

  gltf      reads the .glb files VRF exports
  kv3       parses VRF's text dumps of model blocks (sequences, attachments)
  convert   builds the WC3 model: skeleton, skinning, animation, attachments
  writer    writes MDX version 800
  textures  PNG -> BLP1
  units     which Dota model feeds which map unit, and the animation table
"""

# Bump on any change that alters converted bytes; it is part of the model
# cache key, so players' caches are rebuilt after a launcher update.
CONVERTER_VERSION = 4
