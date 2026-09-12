import "@typespec/json-schema";
using TypeSpec.JsonSchema;

namespace Zed.Governance;

@extension("additionalProperties", false)
model AdmissionFixture {
  @minLength(1)
  id: string;
  count: uint16;
}
