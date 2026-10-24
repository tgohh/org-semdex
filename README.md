# High Level Description
My Own Embedding Solution!



# Setup Instructions
1. Clone mistral.rs. Use this: 
```git clone --branch v0.9.0 https://github.com/EricLBuehler/mistral.rs.git```
	It needs to be at tag v0.9.0 (to address the errors on single item tensors
	when attempting embedding commands).
	I have hardcoded the local location as:
	`/home/<user>/3rdParty/mistral.rs/mistralrs`, but dealer's choice I
	suppose. Make sure to change it in the `Cargo.toml` file.
2. Apply the `mistral.rs.v0.9.0.model_shutdown.patch` to the `mistralrs` repo
3. Run the SQL -> Rust codegen command: 
```sqlc generate```
4. Build the repo!
```cargo build```
5. Create a symlink to the output *.so file generated (when on linux).  As of
   the writing of this, the output of the entire project is:
   `./target/debug/liborg_semdex.so`
   The symlink for this (which is the reccomended way from `emacs-rs`), should
   be emacs compatible, ie, replace "_" with "-".  This is the one I am
   reccomending (for myself)
   ```./target/debug/org-semdex.so -> ./target/debug/liborg_semdex.so```
6. Add the output to the load-path of emacs, and then do a "require" statement
   (it won't load otherwise).  This is what I am using:
   ```
   (add-to-list 'load-path "/path/to/target/debug")
   (require 'org-semdex)
   ```
   

