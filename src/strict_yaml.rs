use serde::{
    de::{DeserializeSeed, Error as _, MapAccess, SeqAccess, Visitor},
    Deserialize, Deserializer,
};
use std::{cell::Cell, collections::BTreeSet, fmt};

const MAX_EXPANDED_YAML_NODES: usize = 100_000;
const MAX_EXPANDED_YAML_SCALAR_BYTES: usize = 8 * 1024 * 1024;

pub(crate) fn validate_strict_yaml(source: &str) -> Result<(), serde_yaml::Error> {
    let budget = StrictYamlBudget::default();
    let mut documents = 0usize;
    for document in serde_yaml::Deserializer::from_str(source) {
        documents += 1;
        if documents > 1 {
            return Err(<serde_yaml::Error as serde::de::Error>::custom(
                "exactly one YAML document is allowed",
            ));
        }
        StrictYamlSeed { budget: &budget }.deserialize(document)?;
    }
    Ok(())
}

#[derive(Default)]
struct StrictYamlBudget {
    nodes: Cell<usize>,
    scalar_bytes: Cell<usize>,
}

impl StrictYamlBudget {
    fn add_node<E: serde::de::Error>(&self) -> Result<(), E> {
        let nodes = self.nodes.get().saturating_add(1);
        if nodes > MAX_EXPANDED_YAML_NODES {
            return Err(E::custom(format!(
                "expanded YAML exceeds the {MAX_EXPANDED_YAML_NODES}-node limit"
            )));
        }
        self.nodes.set(nodes);
        Ok(())
    }

    fn add_scalar_bytes<E: serde::de::Error>(&self, bytes: usize) -> Result<(), E> {
        let scalar_bytes = self.scalar_bytes.get().saturating_add(bytes);
        if scalar_bytes > MAX_EXPANDED_YAML_SCALAR_BYTES {
            return Err(E::custom(format!(
                "expanded YAML exceeds the {MAX_EXPANDED_YAML_SCALAR_BYTES}-byte scalar limit"
            )));
        }
        self.scalar_bytes.set(scalar_bytes);
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct StrictYamlSeed<'a> {
    budget: &'a StrictYamlBudget,
}

impl<'de> DeserializeSeed<'de> for StrictYamlSeed<'_> {
    type Value = ();

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: Deserializer<'de>,
    {
        self.budget.add_node()?;
        deserializer.deserialize_any(StrictYamlVisitor {
            budget: self.budget,
        })
    }
}

struct StrictYamlVisitor<'a> {
    budget: &'a StrictYamlBudget,
}

impl<'de> Visitor<'de> for StrictYamlVisitor<'_> {
    type Value = ();

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("YAML with unique string keys within the expanded-data budget")
    }

    fn visit_bool<E>(self, _value: bool) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_i64<E>(self, _value: i64) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_u64<E>(self, _value: u64) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        if value.is_finite() {
            Ok(())
        } else {
            Err(E::custom("numeric values must be finite"))
        }
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_none<E>(self) -> Result<Self::Value, E> {
        Ok(())
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        self.budget.add_scalar_bytes(value.len())
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        self.budget.add_scalar_bytes(value.len())
    }

    fn visit_bytes<E>(self, value: &[u8]) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        self.budget.add_scalar_bytes(value.len())
    }

    fn visit_byte_buf<E>(self, value: Vec<u8>) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        self.budget.add_scalar_bytes(value.len())
    }

    fn visit_some<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: Deserializer<'de>,
    {
        StrictYamlSeed {
            budget: self.budget,
        }
        .deserialize(deserializer)
    }

    fn visit_newtype_struct<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: Deserializer<'de>,
    {
        StrictYamlSeed {
            budget: self.budget,
        }
        .deserialize(deserializer)
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        while sequence
            .next_element_seed(StrictYamlSeed {
                budget: self.budget,
            })?
            .is_some()
        {}
        Ok(())
    }

    fn visit_map<A>(self, mut mapping: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut keys = BTreeSet::new();
        while let Some(key) = mapping.next_key_seed(StrictYamlKeySeed {
            budget: self.budget,
        })? {
            if !keys.insert(key.clone()) {
                return Err(A::Error::custom(format!("duplicate mapping key `{key}`")));
            }
            mapping.next_value_seed(StrictYamlSeed {
                budget: self.budget,
            })?;
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct StrictYamlKeySeed<'a> {
    budget: &'a StrictYamlBudget,
}

impl<'de> DeserializeSeed<'de> for StrictYamlKeySeed<'_> {
    type Value = String;

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: Deserializer<'de>,
    {
        self.budget.add_node()?;
        let key = String::deserialize(deserializer)?;
        self.budget.add_scalar_bytes(key.len())?;
        Ok(key)
    }
}
