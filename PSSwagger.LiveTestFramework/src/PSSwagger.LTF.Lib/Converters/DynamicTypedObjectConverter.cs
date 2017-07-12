namespace PSSwagger.LTF.Lib.Converters
{
    using System;
    using Newtonsoft.Json;
    using Models;
    using System.Collections.Generic;
    using System.Reflection;
    using Newtonsoft.Json.Linq;

    /// <summary>
    /// Converts JSON objects into a strongly-typed object with different property names from the JSON object when the type is not known at compile time.
    /// </summary>
    public class DynamicTypedObjectConverter : JsonConverter
    {
        private TypeData typeData;

        /// <summary>
        /// Constructor.
        /// </summary>
        /// <param name="typeData">Metadata for type this converter should convert.</param>
        public DynamicTypedObjectConverter(TypeData typeData)
        {
            this.typeData = typeData;
        }

        public override bool CanConvert(Type objectType)
        {
            return objectType.Equals(typeData.Type);
        }

        public override object ReadJson(JsonReader reader, Type objectType, object existingValue, JsonSerializer serializer)
        {
            Dictionary<string, object> dict = serializer.Deserialize<Dictionary<string, object>>(reader);
            Dictionary<string, PropertyInfo> objectTypeProperties = new Dictionary<string, PropertyInfo>();
            foreach (PropertyInfo pi in objectType.GetProperties())
            {
                objectTypeProperties[pi.Name.ToLowerInvariant()] = pi;
            }

            object obj = Activator.CreateInstance(objectType);
            foreach (string prop in dict.Keys)
            {
                string propertyName = prop.ToLowerInvariant();
                object converted;
                if (objectTypeProperties.ContainsKey(propertyName))
                {
                    if (ConvertObject(dict[prop], objectTypeProperties[propertyName].PropertyType, serializer, out converted))
                    {
                        objectTypeProperties[propertyName].SetValue(obj, converted);
                    }
                } else if (typeData.Properties.ContainsKey(propertyName) && objectTypeProperties.ContainsKey(typeData.Properties[propertyName].Name))
                {
                    if (ConvertObject(dict[prop], objectTypeProperties[typeData.Properties[propertyName].Name].PropertyType, serializer, out converted))
                    {
                        objectTypeProperties[typeData.Properties[propertyName].Name].SetValue(obj, converted);
                    }
                }
            }

            return obj;
        }

        private bool ConvertObject(object val, Type expectedType, JsonSerializer serializer, out object converted)
        {
            converted = null;
            bool success = true;
            if (val == null || val.GetType().Equals(expectedType))
            {
                converted = val;
            }
            else if (val is JToken)
            {
                converted = serializer.Deserialize(new JTokenReader(val as JToken), expectedType);
            }
            else
            {
                success = false;
            }

            return success;
        }

        public override void WriteJson(JsonWriter writer, object value, JsonSerializer serializer)
        {
            if (value == null)
            {
                writer.WriteRawValue("null");
                return;
            }
        }
    }
}