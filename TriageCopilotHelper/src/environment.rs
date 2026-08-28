use std::collections::BTreeMap;

const ALLOWED_ENVIRONMENT_KEYS: &[&str] = &["LANG", "LC_ALL", "LC_CTYPE", "TZ"];
const MAX_ENVIRONMENT_VALUE_BYTES: usize = 256;

/// A minimal environment passed to a future bundled runtime.
///
/// Credential, home-directory, CLI-discovery, proxy, and configuration
/// variables are intentionally never inherited.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SanitizedEnvironment(BTreeMap<String, String>);

impl SanitizedEnvironment {
    pub fn from_pairs<I>(pairs: I) -> Self
    where
        I: IntoIterator<Item = (String, String)>,
    {
        let values = pairs
            .into_iter()
            .filter(|(key, value)| {
                ALLOWED_ENVIRONMENT_KEYS.contains(&key.as_str())
                    && value.len() <= MAX_ENVIRONMENT_VALUE_BYTES
                    && !value.contains('\0')
            })
            .collect();
        Self(values)
    }

    pub fn current_process() -> Self {
        Self::from_pairs(
            std::env::vars().filter(|(key, _)| ALLOWED_ENVIRONMENT_KEYS.contains(&key.as_str())),
        )
    }

    pub fn as_pairs(&self) -> Vec<(String, String)> {
        self.0
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect()
    }

    pub fn contains(&self, key: &str) -> bool {
        self.0.contains_key(key)
    }
}

#[cfg(test)]
mod tests {
    use super::SanitizedEnvironment;

    #[test]
    fn environment_keeps_only_small_safe_locale_values() {
        let environment = SanitizedEnvironment::from_pairs([
            ("LANG".to_owned(), "en_AU.UTF-8".to_owned()),
            ("GITHUB_TOKEN".to_owned(), "secret".to_owned()),
            ("COPILOT_HOME".to_owned(), "/unsafe".to_owned()),
            ("HOME".to_owned(), "/Users/example".to_owned()),
            ("TZ".to_owned(), "Australia/Sydney".to_owned()),
        ]);

        assert_eq!(
            environment.as_pairs(),
            vec![
                ("LANG".to_owned(), "en_AU.UTF-8".to_owned()),
                ("TZ".to_owned(), "Australia/Sydney".to_owned())
            ]
        );
        assert!(!environment.contains("GITHUB_TOKEN"));
    }

    #[test]
    fn environment_rejects_oversized_values() {
        let environment = SanitizedEnvironment::from_pairs([("LANG".to_owned(), "x".repeat(257))]);
        assert!(environment.as_pairs().is_empty());
    }
}
