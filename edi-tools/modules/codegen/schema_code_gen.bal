import ballerina/edi;
import ballerina/io;

public function generateCodeForSchema(string ediName, json schema, GenContext context) returns error? {
    edi:EdiSchema ediSchema = check edi:getSchema(schema);
    generateCode(ediName, ediSchema, context);    
}

public function writeCodeForSchema(json schema, string outputPath) returns error? {
    edi:EdiSchema ediSchema = check edi:getSchema(schema);
    GenContext context = {currentEdiName: ediSchema.name, currentEdiRecords: {}};
    generateCode(ediSchema.name, ediSchema, context);
    string recordsString = "";
    foreach BalRecord rec in context.segmentRecords {
        recordsString += rec.toString() + "\n";
    }
    BalRecord[] nonSegmentRecords = context.currentEdiRecords.toArray();
    foreach BalRecord rec in nonSegmentRecords {
        recordsString += rec.toString() + "\n";
    }

    string schemaCode = string `
import ballerina/edi;

public function fromEdiString(string ediText) returns ${ediSchema.name}|error {
    edi:EdiSchema ediSchema = check edi:getSchema(schemaJson);
    json dataJson = check edi:fromEdiString(ediText, ediSchema);
    return dataJson.cloneWithType();
}

public function toEdiString(${ediSchema.name} data) returns string|error {
    edi:EdiSchema ediSchema = check edi:getSchema(schemaJson);
    return edi:toEdiString(data, ediSchema);    
}

${recordsString}

json schemaJson = ${schema.toJsonString()};
    `;

    check io:fileWriteString(outputPath, schemaCode);

}

