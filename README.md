# SkinLab

Make your own League of Legends custom skins on macOS, saved as `.fantome` files for Zushi.

Stage 1 (this version):
- Pick a champion and skin from your League install; see the model in 3D (drag to rotate, scroll to zoom).
- Recolor each texture (hue, saturation, brightness, contrast, tint), or replace it with your own image.
- Export a texture as PNG, paint on it in any app, then bring it back with Replace…
- Save .fantome: only the textures you changed go in. Import it in Zushi's Customs tab.

Stage 2:
- Port from… puts another skin on the current one: a skin from the game (e.g. Yasuo on Camille) or a custom
  .fantome made for another champion. Bones are matched by role (pelvis, spine, arms, legs…), whatever the rig
  (League, 3ds Max Biped, Mixamo, Unreal); limbs are stretched and turned onto the target's, and capes, hair and
  weapons follow their parent bone. Held props are moved into the hands.
- Keep the champion's own head, hands, lower legs or feet when the bodies differ a lot (Camille's blades).
- After porting, unticked parts in Parts are left out of the saved skin.

Normal body proportions (Port from… option):
- Instead of stretching the character's legs to the champion's (Camille's blades), the skin gets its own skeleton
  with legs as long as the character's own, and its own copies of the champion's animations adjusted the same way
  (thigh and shin lengths scaled, hips lowered so the feet stay on the floor). Rotations and timing are untouched.
- "Keep the usual height" draws the skin bigger (the skin's size setting) so it stands as tall as the champion.
- Other skins of the champion keep their own animations; only this skin (and its chromas) use the adjusted copies.

Weapon swap (Port… → "Swap weapons", on by default):
- The champion's weapon becomes the ported skin's weapon, e.g. Gwen on Gragas: his barrel is replaced by her scissors.
- The new weapon is held the way the skin holds it (its grip, found in the skin's own attacks) and fixed to the
  champion's weapon bone (fitted with the champion's attacks), so every animation uses it exactly like the old one:
  swung in attacks, lifted, thrown away and back on Q, and so on.
- Weapons the champion's spells throw become the new weapon too: their spell-effect models (Gragas's Q barrel, its
  pieces and his R cask) are replaced file for file by the skin's weapon, fitted to the same spot and drawn with its
  texture (recolors included). The spells' paths, timing and splashes are unchanged.
- When the champion has no weapon of its own (Camille), the skin's weapons go in her hands instead: each weapon
  (e.g. Mikasa/Yone's two blades) goes to the hand that holds it in the skin's own attacks and Q, in the same grip,
  and is always shown. "Weapon on Spells…" can then give Q/Q2/W the skin's own moves ("Already in her hands");
  clips made of pieces (Yone's Q: Spell1A = Spell1A_01 + Spell1A_02) are joined.
- The weapon's motion-trail shapes (e.g. Gwen's scissor smears) are left out; they need the skin's own effects.

Spell Effects…:
- Per spell (Q, W, E, R, passive, attacks), use the visual effects of another skin of the same champion, e.g.
  Winterblessed Camille's E on a ported skin. The skin's effect table is pointed at that skin's effects, which are
  copied into the skin's file; works on ported skins and on plain recolors. Spells and sounds are unchanged.

Paint (toolbar):
- Paint straight on the 3D model to fix or touch up textures: Paint, Smooth (blends seams and harsh spots),
  Erase (takes paint back off) and Pick Color (from the model). Brush size is on screen, strength sets how much each
  stroke covers; Undo per stroke. Hold ⌥ (Option) to turn the camera while painting. The paint is saved into the
  skin's textures. Parts of a texture shared by both sides of a model (mirrored halves) change together.

3D models (Port from… → From a 3D model):
- MMD models (.pmx), like the official Genshin Impact character models HoYoverse publishes for fans, and most anime
  models. Each material becomes a model part with its own texture (textures in the model's folder; scaled to 1024).
- Japanese bone names are turned into League-style ones (下半身 → Pelvis, 左腕 → L_UpperArm, 右ひざ → R_Calf…; deform
  copies like 足D carry the weights) so the model is fitted to the champion's skeleton like any ported skin.
- Models with more points than a League model holds (65,535) are simplified to fit, keeping texture seams and part
  borders intact.
- Texture files whose Chinese / Japanese names were garbled by unzipping on a Mac ("体.png" saved as "ÃÂ.png") are
  still found.
- Blender files (.blend, 2.8 to 4.x, compressed or not; Blender doesn't need to be installed): what the file shows
  when opened comes in (hidden outfits, variants and other collections stay out), with its mask modifiers and shape
  keys applied as set. Each material's color texture is found through its shader nodes (normal maps, light maps,
  masks skipped; alpha dropped unless the material really is see-through), packed in the file or next to it.
  Auto-Rig Pro style rigs are cleaned up: only bones that move the model are kept, limb halves are joined and the
  hierarchy follows the body.
- glTF models (.gltf with its .bin and textures, or a single .glb: Sketchfab, VRoid, most 3D tools): every mesh with
  its skin weights, shape keys at the file's values, and each material's base color texture (or its color).
  Sizes are normalized, Sketchfab's "_123" name suffixes dropped.
- When bone names don't say the body part (names garbled by a converter, unusual rigs), it's found from the
  skeleton's shape: feet lowest, hands farthest out, head on top, spine and neck on the middle line between.

Weapons… (toolbar):
- A library of weapons, kept between sessions: every skin or model you port or import that has a weapon adds it
  (a model that's only a weapon, like a sword .pmx, goes straight to the library instead of being ported), and
  Add from File… takes one from any .fantome / .pmx / .blend / .gltf / .glb. Each shows as a turning 3D preview.
- Put in Her Hand: the weapon stays in Camille's hand. She always carries it with Zaahen's idle and run (they fit her
  better than Yasuo's): spears like Zaahen's spear, swords by their handle with the blade down. Q takes the chosen
  style's moves: Spear = Zaahen's Q1/Q2 (Flins_Zaahen-Main.fantome), Sword = the Ayaka skin's Q (Kamisato Ayaka
  Yasuo), with the sword moved into the hand and grip she uses for her katana. A W from another skin is kept.

Weapon from Skin… (toolbar):
- Takes a weapon part from any custom skin (e.g. Zaahen's spear) and puts it in Camille's hand for good, in the hand
  and grip that skin uses in its own attacks.
- "Carry it while idle and running": her idle and run animations keep Camille's legs and body but get that skin's arm
  moves (runs matched step for step), so the weapon is carried naturally.
- The weapon hangs from a weapon bone added to her skeleton in that hand. In every animation taken from that skin
  (its idle and runs while carrying, its Q attacks…) the bone moves exactly like that skin's weapon bone, so the weapon
  turns, slides and changes hands in her grip as it does there; in her own animations it stays in her hand.
- Weapon on Spells… then takes Q/Q2/W moves from that skin ("Already in her hands"), e.g. Zaahen's Q attacks, or
  another skin's W (Levi's) with the spear instead of a katana.

SkinLab opens on Camille (the champion list is hidden; show it with the sidebar button).

Animation preview:
- The bar under the 3D view plays the skin's animations (Idle, Run, Attack, Q, Q2, W, E, R, Recall, Dance, and every
  clip in "All"), with the clip's show/hide events. Ported skins play the champion's animations (leg-adjusted with
  normal proportions), exactly what the game will use.

Weapon on Spells (after porting):
- Takes a weapon part of the ported skin (e.g. Ayaka's katana) and fixes it in the right hand in the grip of one of the
  source skin's animations. Each spell given an animation from the source skin draws it (any can keep the champion's
  own); it's also put away on recall, death and emotes.
- Q and Q2: shown when Q is cast, kept out until the second Q and put away after it.
- W: shown for W and put away after it. The picked animation (by default the source's slash that goes most clearly
  from the left to the right, e.g. Ayaka's Attack1) is re-timed to W: the swing keeps its own speed but is held back,
  the stance slowly winding up, so the blade passes in front of the champion exactly when W hits (Camille: 0.75 s,
  measured from her own W, which matches the game's charge time). It's copied to each of W's direction variants
  ("Spell2_0", "Spell2_90"…, the whole body turned like the game's own), and W's return to idle eases from the
  slash's end pose back to the idle pose.
- W can instead use another custom skin's own W ("Another Camille skin's W…", e.g. the Levi Ackerman skin's jump and
  spin): moved onto the champion, its landing blow nudged onto W's hit (Levi's: 0.68 s → 0.75 s, the rest of the
  jump stretched by 10%), and turned for each direction variant like the game's own.
- Animations are moved onto the champion's skeleton: every joint turns like its source joint relative to each
  skeleton's rest pose, bones keep the champion's lengths and the body follows the source's pelvis.
- Put-away events also fire if the spell's animation is cut short (by moving or casting), like the game's own.

Stage 3:
- Colors from Picture… takes the main colors of a picture (the character is cut out of its background with
  Apple's Vision) and recolors every texture with them, keeping the texture's shading and detail.
- Each texture color region gets a picture color of similar lightness; click a pair to pick another color or keep
  the original. Strength slider, and skin tones can stay skin.

Your League folder is only read, never changed.

Build: `./build.sh` (Command Line Tools only).

Credits: zstd (BSD, Meta), xxHash (BSD, Yann Collet). File formats follow the community's open-source
tools (cslol-manager / Zushi's mod-tools).
