#![allow(
    dead_code,
    unused_mut,
    unused_variables,
    clippy::identity_op,
    clippy::too_many_lines,
    clippy::derivable_impls,
    clippy::unit_arg,
    clippy::derive_partial_eq_without_eq,
    clippy::manual_range_patterns,
    clippy::default_trait_access,
    clippy::semicolon_if_nothing_returned,
    clippy::doc_markdown,
    clippy::wildcard_imports
)]
//! DO NOT MODIFY. Auto-generated file

#[derive(Clone, PartialEq, Debug)]
pub struct SumRequest {
    pub a: i32,
    pub b: i32,
}

#[derive(Clone, PartialEq, Debug)]
pub struct SumReply {
    pub result: i32,
}

/// `BenchmarkService` service definition
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BenchmarkService;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BenchmarkServiceMethods {
    GetSum(BenchmarkServiceGetSumMethod),
}

#[derive(Debug, Clone)]
pub struct BenchmarkServiceClient<T>(T);

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub struct BenchmarkServiceGetSumMethod;

impl ::ntex_grpc::MethodDef for BenchmarkServiceGetSumMethod {
    const NAME: &'static str = "GetSum";
    const PATH: ::ntex_grpc::ByteString =
        ::ntex_grpc::ByteString::from_static("/benchmark.BenchmarkService/GetSum");
    type Input = SumRequest;
    type Output = SumReply;
    const CLIENT_STREAMING: bool = false;
    const SERVER_STREAMING: bool = false;
}

mod _priv_impl_benchmark {
    use super::*;

    impl ::ntex_grpc::Message for SumRequest {
        #[inline]
        fn write(&self, dst: &mut ::ntex_grpc::BytePages) {
            ::ntex_grpc::NativeType::serialize(
                &self.a,
                1,
                ::ntex_grpc::types::DefaultValue::Default,
                dst,
            );
            ::ntex_grpc::NativeType::serialize(
                &self.b,
                2,
                ::ntex_grpc::types::DefaultValue::Default,
                dst,
            );
        }

        #[inline]
        fn read(
            src: &mut ::ntex_grpc::Bytes,
        ) -> ::std::result::Result<Self, ::ntex_grpc::DecodeError> {
            let mut msg = Self::default();
            ::ntex_grpc::Message::merge_from(&mut msg, src)?;
            Ok(msg)
        }

        #[inline]
        fn merge_from(
            &mut self,
            src: &mut ::ntex_grpc::Bytes,
        ) -> ::std::result::Result<(), ::ntex_grpc::DecodeError> {
            const STRUCT_NAME: &str = "SumRequest";
            while !src.is_empty() {
                let (tag, wire_type) = ::ntex_grpc::encoding::decode_key(src)?;
                match tag {
                    1 => ::ntex_grpc::NativeType::deserialize(&mut self.a, tag, wire_type, src)
                        .map_err(|err| err.push(STRUCT_NAME, "a"))?,
                    2 => ::ntex_grpc::NativeType::deserialize(&mut self.b, tag, wire_type, src)
                        .map_err(|err| err.push(STRUCT_NAME, "b"))?,
                    _ => ::ntex_grpc::encoding::skip_field(wire_type, tag, src)?,
                }
            }
            Ok(())
        }

        #[inline]
        fn encoded_len(&self) -> usize {
            0 + ::ntex_grpc::NativeType::serialized_len(
                &self.a,
                1,
                ::ntex_grpc::types::DefaultValue::Default,
            ) + ::ntex_grpc::NativeType::serialized_len(
                &self.b,
                2,
                ::ntex_grpc::types::DefaultValue::Default,
            )
        }
    }

    impl ::std::default::Default for SumRequest {
        #[inline]
        fn default() -> Self {
            Self {
                a: ::core::default::Default::default(),
                b: ::core::default::Default::default(),
            }
        }
    }

    impl ::ntex_grpc::Message for SumReply {
        #[inline]
        fn write(&self, dst: &mut ::ntex_grpc::BytePages) {
            ::ntex_grpc::NativeType::serialize(
                &self.result,
                1,
                ::ntex_grpc::types::DefaultValue::Default,
                dst,
            );
        }

        #[inline]
        fn read(
            src: &mut ::ntex_grpc::Bytes,
        ) -> ::std::result::Result<Self, ::ntex_grpc::DecodeError> {
            let mut msg = Self::default();
            ::ntex_grpc::Message::merge_from(&mut msg, src)?;
            Ok(msg)
        }

        #[inline]
        fn merge_from(
            &mut self,
            src: &mut ::ntex_grpc::Bytes,
        ) -> ::std::result::Result<(), ::ntex_grpc::DecodeError> {
            const STRUCT_NAME: &str = "SumReply";
            while !src.is_empty() {
                let (tag, wire_type) = ::ntex_grpc::encoding::decode_key(src)?;
                match tag {
                    1 => {
                        ::ntex_grpc::NativeType::deserialize(&mut self.result, tag, wire_type, src)
                            .map_err(|err| err.push(STRUCT_NAME, "result"))?
                    }
                    _ => ::ntex_grpc::encoding::skip_field(wire_type, tag, src)?,
                }
            }
            Ok(())
        }

        #[inline]
        fn encoded_len(&self) -> usize {
            0 + ::ntex_grpc::NativeType::serialized_len(
                &self.result,
                1,
                ::ntex_grpc::types::DefaultValue::Default,
            )
        }
    }

    impl ::std::default::Default for SumReply {
        #[inline]
        fn default() -> Self {
            Self {
                result: ::core::default::Default::default(),
            }
        }
    }

    impl ::ntex_grpc::ServiceDef for BenchmarkService {
        const NAME: &'static str = "benchmark.BenchmarkService";
        type Methods = BenchmarkServiceMethods;

        #[inline]
        fn method_by_name(name: &str) -> Option<Self::Methods> {
            use ::ntex_grpc::MethodDef;
            match name {
                BenchmarkServiceGetSumMethod::NAME => Some(BenchmarkServiceMethods::GetSum(
                    BenchmarkServiceGetSumMethod,
                )),
                _ => None,
            }
        }
    }

    impl<T> BenchmarkServiceClient<T> {
        #[inline]
        /// Create new client instance
        pub fn new(transport: T) -> Self {
            Self(transport)
        }
    }

    impl<T> ::ntex_grpc::client::ClientInformation<T> for BenchmarkServiceClient<T> {
        #[inline]
        /// Create new client instance
        fn create(transport: T) -> Self {
            Self(transport)
        }

        #[inline]
        /// Get referece to underlying transport
        fn transport(&self) -> &T {
            &self.0
        }

        #[inline]
        /// Get mut referece to underlying transport
        fn transport_mut(&mut self) -> &mut T {
            &mut self.0
        }

        #[inline]
        /// Consume client and return inner transport
        fn into_inner(self) -> T {
            self.0
        }
    }

    impl<T> BenchmarkServiceClient<T> {
        pub fn get_sum<'a>(
            &'a self,
            req: &'a super::SumRequest,
        ) -> ::ntex_grpc::client::Request<'a, T, BenchmarkServiceGetSumMethod> {
            ::ntex_grpc::client::Request::new(&self.0, req)
        }
    }
}
