function generateMainCode(LibData libdata) returns string {
    return string `
public enum EDI_NAME {
    ${libdata.enumBlock}
}

public isolated function getEDINames() returns string[] {
    return ${libdata.ediNames.toString()};
}

public isolated function fromEdiString(string ediText, EDI_NAME ediName) returns anydata|error {
    match ediName {
        ${libdata.ediDeserializers}
        _ => {return error("Unknown EDI name: " + ediName);}
    }
}

public isolated function toEdiString(anydata data, EDI_NAME ediName) returns string|error {
    match ediName {
        ${libdata.ediSerializers}
        _ => {return error("Unknown EDI name: " + ediName);}
    }
}
    `;

}
