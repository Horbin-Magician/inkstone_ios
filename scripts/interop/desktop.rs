use inkstone_core::vault::{Vault, sync::{self, Settings, WebDav}};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let vault = Vault::open(&args[1], &args[2])?;
    let settings = Settings { url: args[3].clone(), username: "interop".into(), ..Default::default() };
    let remote = WebDav::new(&settings, "test-only")?;
    remote.prepare()?;
    sync::synchronize(&vault, &remote, &remote.identity())?;
    Ok(())
}
